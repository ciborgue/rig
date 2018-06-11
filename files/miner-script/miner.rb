#!/usr/bin/ruby
require 'time'
require 'json'
require 'net/http'
require 'rexml/document'
require 'tmpdir'
require 'open3'
require 'serialport'
require 'deep_merge'
require 'syslog/logger'
require 'socket'
require 'yaml'
#require 'pp'

class App
    DEBUG = true
    WDT_SYS = '/dev/watchdog'
    WDT_USB = '/dev/ttyUSB0'
    SYS_DEBUG_DRI = '/sys/kernel/debug/dri'
    RUNTIME = Hash.new
    def initialize
        @syslog = Syslog::Logger.new 'minerScript'

        RUNTIME['rig'] = `ip addr`.each_line.map { |line|
            if /^\s+(link\/ether)\s/.match line
                line.split[0..1].map { |x| x.gsub(/:/, '') }
            elsif /^\s+(inet)\s/.match line
                line.split[0..1]
            end
        }.compact.to_h
        RUNTIME['rig']['gw']=RUNTIME['rig']['inet'].sub(/\d+\/\d+$/, '1')
    end
    def syslog level, message
        $stderr.puts "#{level}: #{message}" if DEBUG
        @syslog.add level, message
    end
	def updateUSB(timeout = 300)
        # unlike @wdt we should close USB watchdog to make sure syslogd
        # can reboot the system immediately upon seeing kernel error
        begin
            SerialPort.open(WDT_USB, 9600, 8, 1, SerialPort::NONE) { |usb|
                usb.putc 0x80
                x = usb.readbyte
                unless x == 0x81
                    syslog Logger::ERROR, "Watchdog (USB: #{WDT_USB}) error [id]"
                    return
                end

                usb.putc (timeout / 10) # USB device uses 10s increments
                x = usb.readbyte
                unless x == (timeout / 10)
                    syslog Logger::ERROR, "Watchdog (USB: #{WDT_USB}) error [value]"
                    return
                end
            } if RUNTIME['watchdog']['usb'] and File.chardev?(WDT_USB)
        rescue Exception => e
            syslog Logger::WARN, "Can't open USB watchdog: " + e.message
        end
	end
    def updateWDT
        # keep @wdt open or else dmesg gets flooded with warnings
        begin
            @wdt = File.open(WDT_SYS, 'w') if @wdt == nil and
                RUNTIME['watchdog']['wdt'] and File.chardev?(WDT_SYS)
            @wdt.putc 0x80 unless @wdt == nil
        rescue Exception => e
            syslog Logger::WARN, "Can't open SYS watchdog: " + e.message
        end
    end
    def sendCEE eventData
        begin
            message = {
                '@timestamp' => Time.now.to_datetime.rfc3339,
                'fromhost' => @rig['inet'],
                'fromhost-mac' => @rig['link/ether'],
                'data' => eventData,
            }
            syslog Logger::INFO, "@cee:#{message.to_json}"
        rescue Exception => e
            syslog Logger::WARN, "Invalid message from miner; stupid ASCII art?"
        end
    end
    def mkInt str
        return str.to_i if /^\d+$/.match str
        str
    end
    def retrieveCardData card
        pm_info = "#{SYS_DEBUG_DRI}/#{card}/amdgpu_pm_info"
        value = Hash.new
        File.open(pm_info).each_line { |line|
            line = line.chomp.split
            if ['(MCLK)', '(SCLK)', '(VDDC)', '(VDDCI)'].include? line[-1]
                value[line[-1][1..-2]] = line[0].to_f
            elsif line[-1] == 'GPU)' and ['(max', '(average'].include? line[-2]
                value["#{line[-2]} #{line[-1]}"[1..-2]] = line[0].to_f
            elsif line[0] == 'GPU' and ['Temperature:', 'Load:'].include? line[1]
                value["#{line[0]} #{line[1]}"[0..-2]] = line[2].to_f
            end
        } if File.exist? pm_info
        value.empty? ? "n/a" : value
    end
    def getClaymoreStatistics(src)
        src = src.split(/:/) # TODO: handle 'file' debug source
        begin
            TCPSocket.open(src[1], src[2].to_i) { |s|
                s.puts '{"id":0,"jsonrpc":"2.0","method":"miner_getstat2"}'
                return JSON.parse(s.read)['result'].collect { |str| str.split /;/ }
            } if src[0] == 'tcp'
            File.open(src[1]) { |s|
                return JSON.parse(s.read)['result'].collect { |str| str.split /;/ }
            } if src[0] == 'file'
            throw "Unknown Claymore report source: #{src.inspect}"
        rescue Exception => e
            syslog Logger::WARN, "miner script can't talk to claymore (yet?)"
        end
    end
    def wemoRequest wemo, attr # TODO implement attr
        begin
            uri = URI("http://#{wemo}/upnp/control/insight1")
            req = Net::HTTP::Post.new(uri)
            req.set_content_type 'text/xml; charset="utf-8"'
            req['SOAPACTION'] = '"urn:Belkin:service:insight:1#GetInsightParams"'
            req.body = '<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetInsightParams xmlns:u="urn:Belkin:service:insight:1"></u:GetInsightParams></s:Body></s:Envelope>'
            Net::HTTP.start(uri.hostname, uri.port).request(req)
        rescue Exception => e
            return nil
        end
    end
    def ping ip
        `ping -c 3 -i 0.25 #{ip}`.each_line { |line|
            next unless line.match /packets transmitted/
            return line.split(/\s+/)[5].to_i < 100
        }
        return false
    end
    def wemoPower wemo
        begin
            throw "Can't ping WeMo device" \
                unless ping wemo.split(/:/)[0]
            xml = REXML::Document.new(wemoRequest(wemo, nil).body)
            xml.root.elements[1].elements[1].elements[1].text.
                split(/\|/)[7].to_f / 1000
        rescue Exception => e
            return nil
        end
    end
    def reportStatistics(args)
        report = getClaymoreStatistics(args)
        cee = {
            'miner' => report[0][0].split[0],
            'uptime' => report[1][0].to_i,
        }
        if RUNTIME.has_key? 'wemo'
            wemo = wemoPower RUNTIME['wemo']['addr']
            cee['wall'] = wemo if wemo.class == Float
        end
        @miner['local']['schema'].inject(cee) { |hash,(k,v)|
            hash[k] = Hash.new
            hash[k]['gpu'] = (0...report[v[0]+1].length).inject({}) { |gpu,i|
                gpu[i] = {
                    'speed' => mkInt(report[v[0]+1][i]) / 1000.0,
                    'accepted' => mkInt(report[v[1]][i]),
                    'rejected' => mkInt(report[v[1]+1][i]),
                    'invalid' => mkInt(report[v[1]+2][i]),
                } unless report[v[0]+1][i] == "off"
                gpu
            }
            hash[k].delete('gpu') if hash[k]['gpu'].empty?
            hash[k]['total'] = {
                'speed' => mkInt(report[v[0]][0]) / 1000.0,
                'total_shares' => mkInt(report[v[0]][1]),
                'rejected_shares' => mkInt(report[v[0]][2]),
                'invalid_shares' => mkInt(report[8][v[2]]),
                'pool_switches' => mkInt(report[8][v[2]+1]),
            } if hash[k].has_key? 'gpu'
            hash.delete(k) if hash[k].empty?
            hash
        }
        cee['gpu'] = Hash.new
        (0...report[3].length).inject(cee['gpu']) { |gpu,i|
            gpu[i] = {
                # temperature will be read from pm_info
                #'temperature' => report[6][i * 2].to_i,
                'fan_speed' => mkInt(report[6][i * 2 + 1]),
            }
            gpu[i].merge! retrieveCardData(i)
            gpu
        }
        cee
    end
    def amdTweak(args) # NOTE args unused for now
        Dir.open(SYS_DEBUG_DRI).each { |card|
            vbios_file = "#{SYS_DEBUG_DRI}/#{card}/amdgpu_vbios"
            next unless File.exist? vbios_file
            tweaks = RUNTIME['amdtweak']['default'].clone
            # check everything, don't break on match - just for simplicity
            `dd if=#{vbios_file} count=1 status=none | strings`.each_line { |s|
                RUNTIME['amdtweak']['model'].each { |model|
                    tweaks.deep_merge!(model[1]) if model[0].match s
                }
            }
            tweaks = "--card #{card} --read-card-pp" +
                tweaks.map { |k,v| " --set '#{k}=#{v}'" }.join
            syslog Logger::INFO, "Running amdtweak: #{tweaks}"
            `( cd ~/amdtweak ; ./amdtweak --quiet #{tweaks} --write-card-pp )`
        }
    end
    def startMiner(args)
        command = @miner['exec'].join(' ') +
            @miner['argv'].map { |k,v|
                " -#{k} #{v}"
            }.join
        syslog Logger::INFO, "Running miner: #{command}"
        Open3.popen3(command) { |stdin,stdout,stderr,thr|
            # avoid UTF errors from ASCII art
            stdout.set_encoding(Encoding::ASCII_8BIT)
            stdout.each_line { |line|
                if @miner['local']['ttli'] != nil and
                    @miner['local']['ttli'].match(line) # log temperature throttle
                    cee = { 'gpu' => Hash.new }
                    cee['gpu'] = line.split(/:\s+/)[1].split(/,\s+/).map { |gpu|
                        gpu = gpu.split(/\s+/)
                        [gpu[0][3..-1].to_i, { 'ttli' => gpu[1][1..-3].to_i.abs }]
                    }.to_h
                    cee['cards_ttlied'] = cee['gpu'].length
                    sendCEE cee
                else
                    @miner['update'].each { |r|
                        next unless r.match(line)
                        updateWDT
                        updateUSB
                        if @lastStatusTimestamp == nil
                            @lastStatusTimestamp = Time.now
                        elsif Time.now - @lastStatusTimestamp > 30
                            sendCEE reportStatistics(@miner['status'])
                            @lastStatusTimestamp = nil
                        end
                    }
                end
            }
        }
    end
    def tftpGetAll section, name
        # Retrieves all files from #{section} (i.e. 'miner.cfg')
        # (currently I only care for 'default' and MAC directory)
        # unlinks file upon return from the yield
        svr='keystone'
        [ 'default', RUNTIME['rig']['link/ether'] ].each { |folder|
            remote = "#{section}/#{folder}/#{name}"
            begin
                Dir::Tmpname.create(Dir.tmpdir) { |tmpname|
                    #syslog Logger::INFO, "TFTP GET: [#{svr}:#{remote}] -> #{tmpname}"
                    `tftp #{svr} -c get #{remote} #{tmpname} 2> /dev/null`
                    if File.exists?(tmpname) and File.size(tmpname) != 0
                        syslog Logger::INFO, "TFTP returned: [#{remote} -> #{tmpname}]"
                        yield tmpname
                    end
                    File.unlink tmpname
                }
            rescue Exception => e # ignore all errors
                syslog Logger::WARN, "Can't load config [#{svr},#{remote}] (#{e})"
            end
        }
    end
    def run(args)
        #RUNTIME['servers'] = [ 'keystone' ]
        #RUNTIME['servers'].push RUNTIME['rig']['gw'] \
        #    if File.exists? '/sys/module/iscsi_ibft' # add if net booted
        tftpGetAll('miner.cfg', 'config.yaml') { |local|
            File.open(local) { |file|
                RUNTIME.deep_merge! YAML.load(file.read)
            }
        }
        File.open('/tmp/debug.yaml', 'w') { |f|
            f.write RUNTIME.to_yaml
        }

        if args.include? '--reboot'
            (0..15).each {
                updateWDT # start reset timer
                updateUSB 2550 # '2550' is the magic for 'reboot now'
                sleep 0.25
            }
            system 'reboot -nf' # last resort if USB reboot failed
        end

        @miner = RUNTIME['miners'][RUNTIME['miner']] # just a shortcut

        tftpGetAll('miner.bin', RUNTIME['miner'] + '.tar.xz') { |local|
            command = "tar xCJf ~ #{local}"
            syslog Logger::INFO, command
            `#{command}`
        }

        @miner['pools'].each { |name| # dpools.txt, epools.txt, etc.
            syslog Logger::INFO, "rm -f ~/#{RUNTIME['miner']}/#{name}"
            tftpGetAll('miner.cfg', "#{RUNTIME['miner']}/#{name}") { |local|
                command = "cp #{local} ~/#{RUNTIME['miner']}/#{name}"
                syslog Logger::INFO, command
                `#{command}`
            }
        }

        updateUSB
        updateWDT

        amdTweak(args)
        startMiner(args)
    end
end
App.new.run(ARGV)
# vim: set ts=4 sw=4 expandtab:
