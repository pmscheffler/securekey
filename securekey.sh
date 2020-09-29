#!/bin/bash

host="10.1.1.8"
user="admin"
idfile="~/.ssh/bigip"

partition="Common"

# The Cipher to encrypt the Key
# Available are: aes128, aes192, aes256, camellia128, camellia192, camellia256, des (which you definitely should avoid), des3 or idea
cipher="aes256"

# Password to add to the Key
# To-Do: should read this from a list or something...
keyphrase="HngajP9s4NsL"

# ensure we have a place to work in ... if not, use the local dir
dir=.

echo "Working in {$dir} with user {$user} and idfile {$idfile} for partition {$partition}"

# we need the folders set up, make them if they don't exist
mkdir -p $dir/incoming
mkdir -p $dir/protected
mkdir -p $dir/pre-protected
mkdir -p $dir/sent
mkdir -p $dir/imported

# get the files from the BIG-IP
scp -q -i $idfile -p $user@$host:/config/filestore/files_d/${partition}_d/certificate_key_d/\:$partition\:* $dir/incoming/

# remove the F5 Default keys
echo "Removing the F5 Default Keys from the process"
rm $dir/incoming/\:Common\:default*

# move the ones that are already protected
echo "Removing any already protected keys from the process"
grep -H -i -l ",encrypted" $dir/incoming/* | xargs -d '\n' mv -t $dir/pre-protected/.

# Now we have the list of Keys in this Partition which need to be enciphered and put back in
echo "Enciphering keys with supplied password"
cd $dir/incoming
for unciphered in *; do openssl rsa -$cipher -in $unciphered -out ../protected/$unciphered -passout pass:$keyphrase ; done

