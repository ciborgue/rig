#!/bin/bash
# Only load Tor config from 'keystone', regardless of whether we boot
# locally from the USB or remotely from iSCSI.
retrieve_hidden_keys() {
  hostname=$(uname -n | sed -e 's/-.*//') # make 'nova' from 'nova-004'

  # Step 1: get torrc & torsocks.conf - use 'default'
  for file in torrc torsocks.conf; do
    for base in default $hostname; do
      tmpfile=$(mktemp -u)
      tftp keystone -c get tor.cfg/$base/$file $tmpfile 2> /dev/null
      if [[ -s $tmpfile ]]; then
        cp $tmpfile /etc/tor/$file
        chown root:root /etc/tor/$file
        chmod 0644 /etc/tor/$file
      fi
    done
  done

  # Step 2: get keyfiles - don't use 'default' directory
  for where in $(cat /etc/tor/torrc |
    sed -e '/^HiddenServiceDir\s/!d;s/\/*\s*$//;s/^.*\s//'); do
    [[ -d $where ]] || mkdir $where
    chown debian-tor:debian-tor $where
    chmod 2700 $where
    service=$(basename $where)
    for file in private_key; do
      tmpfile=$(mktemp -u)
      tftp keystone -c get tor.cfg/$hostname/$service/$file $tmpfile 2> /dev/null
      if [[ -s $tmpfile ]]; then
        cp $tmpfile $where/$file
        chown debian-tor:debian-tor $where/$file
        chmod 600 $where/$file
      fi
    done
  done
}

retrieve_hidden_keys
