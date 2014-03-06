#!/bin/bash
# Defines a general purpose UUENCODING-as-TXT scheme.
# Run as ./dnsfilee.sh FILE DNS-LOCATION

if [ $# != 2 ]; then echo "Need file and dns suffix"; exit 1; fi

FILE=$1
DNSFILE=$2
DNSTIME=$((24*60*60))

encode_counted_line() {
        # DJBDNS:
        sed -e 's/\\/\\134/g' -e 's/:/\\072/g' \
          | awk -e "//{ print \$1\".$1:\"\$2\":$DNSTIME\"; }"
        # BIND:
        # sed -e "s/\s*\([0-9][0-9]*\)\s*\(.*\)/\1.$DNSFILE $DNSTIME IN TXT \"\2\"/"
}
encode_raw_line() {
        # DJBDNS:
        sed -e 's/\\/\\134/g' -e 's/:/\\072/g' -e "s/\(.*\)/'$1:\1:$DNSTIME/"
        # BIND:
        # sed -e "s/\(.*\)/$1.$DNSFILE $DNSTIME IN TXT \"\1\"/"
}

dosha() {
        # Linux
        sha1sum | cut -f 1 -d ' '
        # BSD
        # sha1 | sed -e "s/.* \([0-9a-f]*\)\$/\1/" |
}

uuencode `basename $FILE` < $FILE | cat -n | encode_counted_line "$DNSFILE"
cat $FILE | dosha | encode_raw_line "sha1.$DNSFILE"
