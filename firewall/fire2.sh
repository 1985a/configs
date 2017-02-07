#!/bin/env bash
# -- UTF 8 --
# This script works better on Archlinux. It was made on Archlinux, so if you found something stranger, you've been warned

# Some common variables
# Where are these programs??

echo="/bin/echo"
iptables="$(which iptables)"
modprobe="$(which modprobe)"
awk="$(which awk)"
cut="$(which cut)"
ip="$(which ip)"

# Failsafe - die if /usr/bin/iptables not found
#[ ! -x "$iptables" ] && { echo "$0: \"${iptables}\" there is an error, iptables was not found."; exit 1;

# Other variables
input="$iptables -A INPUT"
output="$iptables -A OUTPUT"
forward="$iptables -A FORWARD"
prerouting="$iptables -A PREROUTING -t nat"
funfact="$input"
ok="-j ACCEPT"
drop="-j DROP"
log="-j LOG --log-prefix"
level="--log-level"
#Streaming ports
asculta_radio_port="9744"
formula_inter_port="8300"
ibiza_global_port="8024"
#
SSH_port_phone="5522"
# Torrent's ports
rtport1="16420"
rtport2="6881"
rtport3="6969"

# IRSSI ports
irssi="6697,7000,7070"
#
red_net="$(${ip} route | ${awk} '/dev.*proto/{print $NE; exit}' | ${cut} -d ' ' -f1)"
active_face="$(${ip} addr show | ${awk} '/inet.*brd/{print $NF; exit}')"
internal_ip="$(${ip} addr show ${active_face} | grep "inet\b" | ${awk} '{print $2}' | ${cut} -d/ -f1)"

#red_net2="$(${ip} route | ${awk} '/dev.*proto/{print $NE; exit}' | ${cut} -d ' ' -f1)"

#N3ds_client="192.168.10.42/24"
N3ds_port="5000"
SSH_port="44220"
spoof_ips="0.0.0.0/8 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 224.0.0.0/3"

# Load these modules to allow better analyze and LOG

$modprobe nf_conntrack
$modprobe nf_conntrack_ftp
$modprobe xt_conntrack
$modprobe xt_LOG
$modprobe xt_state
$modprobe ipt_LOG
$modprobe nf_nat
# Clear the tables or existent rules on 'em
$iptables -X
$iptables -Z
$iptables -t nat -F

# Other rules that needs to be flushed
$iptables -F
$iptables -t nat -X
$iptables -t raw -F
$iptables -t raw -X
$iptables -t security -F
$iptables -t security -X
$iptables -t mangle -F
$iptables -t mangle -X

# By default the policy'll be DROP
# FILTER
$iptables -P INPUT DROP
$iptables -P FORWARD DROP
$iptables -P OUTPUT DROP

# Allow everythings on localhost
$input -i lo $ok -m comment --comment "Local HOST"
$output -o lo $ok -m comment --comment "Local HOST"
#$forward ! -i $inside_net -m conntrack --ctstate NEW $ok

$input -m conntrack --ctstate INVALID $drop

# Allow pdnsd works

$input -p udp -m udp --sport domain -m conntrack --ctstate ESTABLISHED,RELATED $ok -m comment --comment "dns port (53)"
$output -p udp -m udp --dport domain -m conntrack --ctstate NEW,ESTABLISHED $ok -m comment --comment "dns port (53)"

# Allow access from all subnet
$input -p tcp -s $red_net $ok -m comment --comment="subnet access"
$output -p tcp -s $red_net $ok -m comment --comment="subnet_access"

# Theses rules are here to allow conections from others computers

# fix send_packet: Operation not permitted due to missing 68 udp port
# via: http://serverfault.com/questions/240913/dhcp-request-error-send-packet-not-permitted-how-to-debug-what-does-it-mean
$input -p udp -m udp -m conntrack --ctstate NEW --dport 67:68 $ok -m comment --comment "port 67"
$input -p udp -m udp -m conntrack --ctstate NEW --dport domain $ok -m comment --comment "port 53"
$input -p tcp -m tcp -m conntrack --ctstate NEW --dport domain $ok

$iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o $active_face -j MASQUERADE

#$forward -i $active_face -s 10.10.10.0/24 -o wlan2 -d 192.168.10.0/24 -p udp --dport domain $ok

#$forward -i $active_face -s $red_net -o wlan2 -d 10.10.10.0/24 -p tcp -m tcp --dport ssh $ok
#$input -i wlan2 -s $red_net -d 10.10.10.44 -p tcp --dport ssh -j ACCEPT
#$output -o wlan2 -d $red_net -s 10.10.10.44 -p tcp --sport ssh -j ACCEPT

$forward -i wlan2 -s 10.0.0.0/24 -o $active_face -d 8.8.8.8 -p udp --dport domain $ok

$forward -i $active_face -o wlan2 -m conntrack --ctstate RELATED,ESTABLISHED $ok -m comment --comment "a lot of people've pased here"
$forward -i wlan2 -o $active_face $ok -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment " a lot of people II here"
#$forward -d 10.10.10.0/24 -i $active_face $ok
#$forward -s 10.10.10.0/24 -i wlan2 $ok

$prerouting -p tcp -i $active_face -d $internal_ip --dport 5522 -j DNAT --to 10.10.10.34

$forward -i $active_face -s $internal_ip -o wlan2 -d 10.10.10.34 -p tcp --dport 5522 -m conntrack --ctstate NEW $ok
$forward -o $active_face -d $internal_ip -i wlan2 -s 10.10.10.34 -p tcp --sport 5522 -m conntrack --ctstate NEW,ESTABLISHED $ok


#$forward -i $active_face -o wlan2 -p tcp --dport 5522 --destination 10.10.10.34 -m conntrack --ctstate NEW,ESTABLISHED $ok

#$forward -i wlan2 -o $active_face -m conntrack --ctstate RELATED,ESTABLISHED $ok

$forward -j REJECT


# Theses rules allow to go to the Internet
$input -p tcp -m tcp --sport http -m conntrack --ctstate ESTABLISHED $ok -m comment --comment "http insecure (80) port"
$output -p tcp -m tcp --dport http -m conntrack --ctstate NEW,ESTABLISHED $ok -m comment --comment "http insecure (80) port"

$input -p tcp -m tcp --sport https -m conntrack --ctstate ESTABLISHED $ok -m comment --comment "https secure (443) port"
$output -p tcp -m tcp --dport https -m conntrack --ctstate NEW,ESTABLISHED $ok -m comment --comment "https secure (443) port"

# Allow to upload CIA's to 3DS system
$output -p tcp -m tcp --dport $N3ds_port -m conntrack --ctstate ESTABLISHED $log "N3DS is Working now-OUT: " --log-level 7
$output -p tcp -m tcp --dport $N3ds_port -m conntrack --ctstate ESTABLISHED $ok -m comment --comment "3DS FBI port"
$input -p tcp -m tcp --sport $N3ds_port -m conntrack --ctstate NEW,ESTABLISHED $log "N3DS is Working now-IN: " --log-level 7
$input -p tcp -m tcp --sport $N3ds_port -m conntrack --ctstate NEW,ESTABLISHED $ok -m comment --comment "3DS FBI port"


# Allow to works ftp service
$output -p tcp -m tcp -m multiport --dports 21000,21010 -s 127.0.0.1 -m conntrack --ctstate ESTABLISHED $ok
$input -p tcp -m tcp -m multiport --sports 21000,21010 -s 127.0.0.1 -m conntrack --ctstate NEW,ESTABLISHED $ok

# irssi ports output mode rules
$input  -p tcp -m multiport --dports $irssi -m conntrack --ctstate NEW,ESTABLISHED $ok
$output -p tcp -m multiport --dports $irssi -m conntrack --ctstate ESTABLISHED $ok


# Allow streaming from internet
# Asculta RadioLive.ro
$input -p tcp -m tcp --sport $asculta_radio_port -m conntrack --ctstate ESTABLISHED $ok -m comment --comment "Asculta Radio Live"
$output -p tcp -m tcp --dport $asculta_radio_port -m conntrack --ctstate NEW,ESTABLISHED $ok -m comment --comment "Asculta Radio Live"

# Formula Internacional
$input -p tcp -m tcp --sport $formula_inter_port -m conntrack --ctstate ESTABLISHED $ok -m comment --comment "Formula Internacional"
$output -p tcp -m tcp --dport $formula_inter_port -m conntrack --ctstate NEW,ESTABLISHED $ok -m comment --comment "Formula Internacional"

# Ibiza Global Radio
$input -p tcp -m tcp --sport $ibiza_global_port -m conntrack --ctstate ESTABLISHED $ok -m comment --comment "Ibiza Global Radio"
$output -p tcp -m tcp --dport $ibiza_global_port -m conntrack --ctstate NEW,ESTABLISHED $ok -m comment --comment "Ibiza Global Radio"

# Allow outgoing connections ssh standard port
$output -p tcp --dport $SSH_port -m conntrack --ctstate NEW,ESTABLISHED $ok -m comment --comment "ssh_outgoing port"
$input -p tcp --sport $SSH_port -m conntrack --ctstate ESTABLISHED $ok -m comment --comment "ssh_outgoing port"


# rTorrent's rules

$input -p tcp -m tcp --dport $rtport1 -m conntrack --ctstate ESTABLISHED $ok
$output -p tcp --sport $rtport1 -m conntrack --ctstate NEW,ESTABLISHED $ok

$input -p udp -m udp --dport $rtport2 -m conntrack --ctstate ESTABLISHED $ok
$output -p udp -m udp --sport $rtport2 -m conntrack --ctstate NEW,ESTABLISHED $ok

$output -p udp -m udp --dport $rtport3 -m conntrack --ctstate NEW,ESTABLISHED $ok

#


# To enable, uncomment it
#Allow incoming connections ssh standard port
# Protecting against brute force attacks
$iptables -N LOG_SSH
$input -p tcp -m tcp --dport $SSH_port -m conntrack --ctstate NEW -m recent --set --name DEFAULT --rsource -m comment --comment "port_sshd 44220"
$input -p tcp -m tcp --dport $SSH_port -m conntrack --ctstate NEW -m recent --update --seconds 90 --hitcount 4 --name DEFAULT --rsource -j LOG_SSH
$input -p tcp --sport $SSH_port -m conntrack --ctstate NEW,ESTABLISHED $ok
$input -p tcp --syn --dport $SSH_port -m connlimit --connlimit-above 3 -j REJECT
$iptables -A LOG_SSH $log "SSH_deny: " --log-level 7
$iptables -A LOG_SSH $drop
$output -p tcp --dport $SSH_port -m conntrack --ctstate ESTABLISHED $ok


# Allow to incoming connections through git standar port
$input -p tcp --sport git -m conntrack --ctstate ESTABLISHED $ok -m comment --comment "git standard (9418) port"
$output -p tcp --dport git -m conntrack --ctstate NEW,ESTABLISHED $ok -m comment --comment "git standard (9418) port"

# Allow ping from out and inside of computer
$output -p icmp -o $active_face -m conntrack  --ctstate NEW,ESTABLISHED,RELATED $ok
$input -p icmp -i $active_face -m conntrack --ctstate ESTABLISHED,RELATED $ok

# For Hostapd

$output -p icmp -o wlan2 -m conntrack --ctstate NEW,ESTABLISHED,RELATE $ok
$input -p icmp -i wlan2 -m conntrack --ctstate ESTABLISHED,RELATED $ok


#Anti-MiM
# Linux Iptables Avoid IP Spoofing And Bad Addresses Attacks
#From WAN
$input -i $active_face -s $internal_ip $drop
$forward -i wlan2 -s 10.10.10.10/24 $drop
$forward -o wlan2 -s 10.10.10.10/24 $drop
$output -o $active_face -s $internal_ip $drop

#From LAN
$input -i $active_face -s $red_net $drop
$forward -i wlan2 -s 10.10.10.0/24 $drop
$forward -o wlan2 -s 10.10.10.0/24 $drop
$output -o $active_face -s $red_net $drop

# Drop all spoofed_ips
for ip in $spoof_ips
do
	$input -i $active_face -s $ip $drop -m comment --comment "getout spoof_ips"
	$input -i wlan2 -s $ip $drop
	$output -o $active_face -s $ip $drop -m comment --comment "getout spoof_ips"
	$output -o wlan2 -s $ip $drop
done

# Anti-flooding o inundación de tramas SYN-FLOOD.
$iptables -N syn-flood
$iptables -A syn-flood -m limit --limit 10/second --limit-burst 50 -j RETURN
$iptables -A syn-flood $log "SYN flood: "
$iptables -A syn-flood $drop

# FunFACTs!! excuse me Sheldon
$iptables -N FUNFACT
$funfact -p TCP -m conntrack --ctstate RELATED,ESTABLISHED $ok
$funfact -p UDP -m conntrack --ctstate RELATED,ESTABLISHED $ok
$funfact -p ICMP -m conntrack --ctstate RELATED,ESTABLISHED $ok
$input -p ICMP -m conntrack --ctstate RELATED,ESTABLISHED -j FUNFACT
$funfact -m conntrack --ctstate INVALID -j REJECT
$iptables -A FUNFACT $log "FW_INVALID: " $level 7
#$funfact -p tcp --tcp-flags ACK,FIN FIN $log "FIN: " $level 7 
#$funfact -p tcp --tcp-flags ACK,FIN FIN -j REJECT
#$funfact -p tcp --tcp-flags ACK,PSH PSH $log "PSH: " $level 7
#$funfact -p tcp --tcp-flags ACK,PSH PSH -j REJECT
#$funfact -p tcp --tcp-flags ACK,URG URG $log "URG: " $level 7
#$funfact -p tcp --tcp-flags ACK,URG URG -j REJECT
#$funfact -p tcp --tcp-flags ALL FIN,PSH,URG $log "XMAS scan DROP: " $level 7
#$funfact -p tcp --tcp-flags ALL ALL -j REJECT
#$funfact -p tcp --tcp-flags ALL NONE $log "NULL scan: " $level 7
#$funfact -p tcp --tcp-flags ALL NONE -j REJECT
#$funfact -p tcp --tcp-flags ALL SYN,RST,ACK,FIN,URG $log "pscan: " $level 7
#$funfact -p tcp --tcp-flags ALL SYN,RST,ACK,FIN,URG -j REJECT
#$funfact -p tcp --tcp-flags SYN,FIN SYN,FIN $log "pscan 2: " $level 7
#$funfact -p tcp --tcp-flags SYN,FIN SYN,FIN -j REJECT
#$funfact -p tcp --tcp-flags FIN,RST FIN,RST $log "pscan 2: " $level 7
#$funfact -p tcp --tcp-flags FIN,RST FIN,RST -j REJECT
#$funfact -p tcp --tcp-flags ALL SYN,FIN $log "SYNFIN-SCAN: " $level 7
#$funfact -p tcp --tcp-flags ALL SYN,FIN -j REJECT
#$funfact -p tcp --tcp-flags ALL URG,PSH,FIN $log "NMAP-XMAS-SCAN: " $level 7
#$funfact -p tcp --tcp-flags ALL URG,PSH,FIN -j REJECT
#$funfact -p tcp --tcp-flags ALL FIN $log "FIN-SCAN: " $level 7
#$funfact -p tcp --tcp-flags ALL FIN -j REJECT
#$funfact -p tcp --tcp-flags ALL URG,PSH,SYN,FIN $log "NMAP-ID: " $level 7
#$funfact -p tcp --tcp-flags ALL URG,PSH,SYN,FIN -j REJECT
#$funfact -p tcp --tcp-flags SYN,RST SYN,RST $log "SYN-RST: " $level 7


#Other harderning
# Force SYN packets check
#$input -p tcp ! --syn -m conntrack --ctstate NEW $drop
$input -p tcp -m conntrack --ctstate NEW ! --syn $log "Force SYN packets check: " -m comment --comment "Force SYN packets check"
$input -p tcp -m conntrack --ctstate NEW ! --syn $drop -m comment --comment "Force SYN packets check"


#Force Fragments packets check
$input -f $drop 


# For debugging, use e.g.:
# * tcpdump, to see the packets - run tcpdump on the PCs involved.
# * iptables rate-limited logging, to gain insight into how the iptables rules are working. E.g.:

$input -m limit --limit 10/min --limit-burst 10 $log "rate-limited attempt: " --log-level warning

##prevent UDP flooding general
$iptables -N udp-flood
$output -p udp -j udp-flood
$iptables -A udp-flood -p udp -m limit --limit 50/s --limit-burst 4 -j RETURN
$iptables -A udp-flood $log 'UDP-flood attempt: ' --log-level 4
$iptables -A udp-flood $drop

# Blocking DNS Amplification attacks
# Use the string module of iptables to block all packets that contain isc.org and ripe.
$input -p udp -m string --hex-string "|03697363036f726700|" --algo bm --to 65535 $drop
$input -p udp -m udp --dport 53 -m limit --limit 5/sec $log "fw-dns " --log-level 7

##prevent amplification attack
$iptables -N DNSAMPLY
$iptables -A DNSAMPLY -p udp -m state --state NEW -m udp --dport 53 $ok
$iptables -A DNSAMPLY -p udp -m hashlimit --hashlimit-srcmask 24 --hashlimit-mode srcip --hashlimit-upto 30/m --hashlimit-burst 10 --hashlimit-name DNSTHROTTLE --dport 53 -j DNSAMPLY
$iptables -A DNSAMPLY $log "FW_DNS-BLOCK: " --log-level 7
$iptables -A DNSAMPLY -p udp -m udp --dport 53 $drop

# log before DROP
$input $log "FW_INPUT drop: "  -m limit --limit 12/min --limit-burst 7 --log-level 7
$output  $drop
$input $log "FW_OUTPUT drop: "  -m limit --limit 12/min --limit-burst 7 --log-level 7
$output $drop
$input $log "FW_FORWARD drop: " -m limit --limit 12/min --limit-burst 7 --log-level 7
$output $drop

# log after DROP
$input $log "FW_INPUT: " -m limit --limit 12/min --limit-burst 7 --log-level 7
$output $log "FW_OUTPUT: " -m limit --limit 12/min --limit-burst 7 --log-level 7
$forward $log "FW_FORWARD: " -m limit --limit 12/min --limit-burst 7 --log-level 7

# Close all foreing people
$input -s 0/0 -d 0/0 -p udp $drop
$input -s 0/0 -d 0/0 -p tcp --syn $drop

# Finally it's time to activate the MAGIC :P that is the router
#$echo "0" > /proc/sys/net/ipv4/ip_forward
