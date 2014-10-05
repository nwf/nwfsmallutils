#!/usr/bin/gawk -f
#
# Maintains /etc/resolv.conf and provides USR1 signals to openvpn
# processes.  Intended for use inside chroot environments ala
# Lil' Debi or others.
#
# Run me against the watchprops program, as in
# gawk -f watchprops-netevents.gawk <(/system/bin/watchprops 2>&1)

function set_dns(   out_file)
{

  out_file = "/etc/resolv.conf"

  in_file = "/system/bin/getprop net.dns1 8.8.8.8" 
  if ((in_file | getline) > 0) {
    print "nameserver " $0
    print "nameserver " $0 > out_file
  }
  close(in_file)

  in_file = "/system/bin/getprop net.dns2 8.8.8.8" 
  if ((in_file | getline) > 0) {
    print "nameserver " $0
    print "nameserver " $0 >> out_file
  }
  close(in_file)

  close(out_file)
}

function signal_vpns() {
   ka="pkill -USR1 openvpn"
   ka | getline
   close(ka)
}


BEGIN{
  lasttime = systime()
  set_dns()
}

/ net.dns.*/{
  if ( systime() > lasttime) {
    lasttime = systime()
    set_dns()
    signal_vpns()
  }
}
