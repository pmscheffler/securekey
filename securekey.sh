#!/bin/bash

# F5 Networks Script to pull keys from BIG-IP, add a password to them and post them back to the BIG-IP

# Where we are transferring the files to/from (scp)
host="10.1.1.8"
# User for the BIG-IP scp commands
user="admin"

# ID File for authenticating to the BIG-IP command line for scp
# ****** Note that you will need to do a ssh-copy-id to set this up to get it to work
# ****** Also note that if the user has their account to default to "TMSH" you can't log in, the default _must_ be Bash
idfile="~/.ssh/bigip"

# Authortization for API access to BIG-IP
auth_token=""

# BIG-IP Partition to work on
# To-Do: make this a parameter
partition="Common"

# The Cipher to encrypt the Key
# Available are: aes128, aes192, aes256, camellia128, camellia192, camellia256, des (which you definitely should avoid), des3 or idea
cipher="aes256"

# Password to add to the Key
keyphrase="HngajP9s4NsL"

# ensure we have a place to work in ... if not, use the local dir
dir=.

# remote directory where the keys are pushed to be loaded
remotedir="/var/tmp/protected-keys/"

# token for API calls
auth_token="Basic YWRtaW46YWRtaW4="

# ToDo: Need to ensure that C3D isn't broken by this replacement

for i in "$@"
do
case $i in
    -h=*|--host=*)
    host="${i#*=}"
    shift # past argument=value
    ;;
    -p=*|--partition=*)
    partition="${i#*=}"
    shift # past argument=value
    ;;
    -a=*|--auth_token=*)
    auth_token="${i#*=}"
    shift # past argument=value
    ;;
    -i=*|--idfile=*)
    idfile="${i#*=}"
    shift # past argument=value
    ;;
    -c=*|--cipher=*)
    cipher="${i#*=}"
    shift # past argument=value
    ;;
    -u=*|--user=*)
    user="${i#*=}"
    shift # past argument=value
    ;;
    -k=*|--keyphrase=*)
    keyphrase="${i#*=}"
    shift # past argument=value
    ;;
    -d=*|--dir=*)
    dir="${i#*=}"
    shift # past argument=value
    ;;
    --clean)
    clean="YES"
    shift # past argument=value
    ;;
    --default)
    DEFAULT=YES
    shift # past argument with no value
    ;;
    *)
          # unknown option
    ;;
esac
done

echo "Working in $dir with user $user@$host and idfile $idfile for partition $partition"

if [ -z "$clean" ] 
then

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

    # create temp dir to put files into on BIG-IP
    ssh -i $idfile $user@$host "mkdir -p $remotedir"

    cd $dir/incoming
    for unciphered in *
        do 
            # ToDo: here we _could_ open a file and get the keyphrase from a list that correlates to the key name...
            echo "Processing $unciphered"
            openssl rsa -$cipher -in $unciphered -out "../protected/"$unciphered"_protected" -passout pass:$keyphrase

            scp -q -i $idfile "../protected/"$unciphered"_protected" $user@$host:/var/tmp/protected-keys/

            # move the file out of the protected dir to sent
            mv "../protected/"$unciphered"_protected" ../sent/

            # create the name for the imported key
            rootname="$(echo $unciphered | awk ' BEGIN {FS=":"} {print $3}' | awk ' BEGIN {FS="_" } {print $1 }')"
            protectedkeyname="${rootname}_protected"

            # echo "UKN: $unciphered PKN: $protectedkeyname"

            # import the key
            unciphered_fixed=$(echo "$unciphered" | sed 's/:/\\:/g')
            # echo "Fixed: $unciphered_fixed"
            payload="{\"command\": \"install\", \"name\": \""$protectedkeyname"\", \"security-type\": \"password\", \"from-local-file\": \"/var/tmp/protected-keys/"$unciphered"_protected\" }"
            # echo "Payload: $payload"

            url="https://${host}/mgmt/tm/sys/crypto/key"
            auth_header="Authorization: $auth_token"
            content_type="Content-Type: application/json"

            # echo \
            # curl -k --location --request POST $url --header "$header" --header "$content_type" --data-raw "$payload"
            res=$(curl -sw '%{http_code}' --output /dev/null -k --location --request POST $url --header "$auth_header" --header "$content_type" --data-raw "$payload" )

            # echo "res: $res"

            # FIXED: test if call was successful
            if [ $res -eq 200 ]
            then
                url="https://$host/mgmt/tm/ltm/profile/client-ssl"

                # echo "CP: curl -s -k --location --request GET $url --header "\'$auth_header\'" --data-raw '' | jq -r --arg kname "\"/$partition/$rootname\"" '.items[] | if .key == \$kname then .name else empty end '"
                # clientprofiles=$(
                clientprofiles=""
                content=$(curl -s -k --location --request GET $url --header "$auth_header" --data-raw '')
                keyname="/$partition/$rootname"
                # echo "keyname: $keyname"

                clientprofiles=$(echo "${content}" | jq -r --arg keyname "$keyname"  '.items[] | select(.key==$keyname) | .key ' )
                # echo "Data: $clientprofiles"

                # url="https://$host/mgmt/tm/ltm/profile/server-ssl"
                # serverprofiles=$(curl -s -k --location --request GET $url --header "$auth_header" --data-raw '' | jq -r --arg kname "{$partition}/{$unciphered}" '.items[] | if .key == $kname then .name else empty end ')

                if [ ! -z "$clientprofiles" ]
                then
                    while IFS= read -r clientprofile; do
                        echo "Updating Client Profile $clientprofile"
                        
                    done <<< "$clientprofiles"
                fi
                # for clientprofiles 
            else
                echo "Failed to install new protected key"
            fi
        done

    # push the protected files to the BIG-IP
    # note that you need to put the files where the BIG-IP can reference them

   
    # send files via tmsh api
    

elif [[ $clean -eq YES ]]
then
    rm -rf incoming/*
    rm -rf pre-protected/*
    rm -rf protected/*
    rm -rf sent/*

    # remove temp dir to put files into on BIG-IP
    ssh -i $idfile $user@$host "rm -rf $remotedir"

else
    echo "Exiting without doing anything"
fi