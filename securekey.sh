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
    -s*|--secret*)
    read -sp 'Please enter the passphrase: ' keyphrase
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
    -?|--help)
    echo "This script will automate the creation of encrypted keys for an existing BIG-IP"
    echo "Copyright 2020 - F5 Networks / Peter Scheffler"
    echo ""
    echo "Parameters:"
    echo "-h / --host:          The name or IP address of the BIG-IP Management NIC"
    echo "-u / --user:          The user to use with the ID file for ssh/scp access to the BIG-IP"
    echo "-i / --idfile:        An ssh ID file with a private key that has been configured to work with the BIG-IP for ssh and scp access"
    echo "-a / --auth_token:    An existing authorization token for the BIG-IP API that can update certs, keys and profiles (Admin or Cert Manager)"
    echo "-p / --partition:     The partition where the Keys and Profiles are stored"
    echo "-c / --cipher:        The cipher scheme to use to encrypt the keys"
    echo "                      Available are: aes128, aes192, aes256, camellia128, camellia192, camellia256, des (which you definitely should avoid), des3 or idea"
    echo "-k / --keyphrase:     The passphrase that will be added to the keys"
    echo "-s / --secret:        Interactively enter the passphrase so that it's not stored in a file or seen as a paramter"
    echo "-d / --dir:           Allows for another directory to be used to locally store the keys (default is current)"
    echo "--clean:              Remove all of the keys in the -d directory"
    echo "-? / --help:          You're looking at it"
    echo ""
    exit 1
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

    echo ""

    cd $dir/incoming
    for unciphered in *
        do 
            # ToDo: here we _could_ open a file and get the keyphrase from a list that correlates to the key name...

            # create the name for the imported key
            rootname="$(echo $unciphered | awk ' BEGIN {FS=":"} {print $3}' | awk ' BEGIN {FS="_" } {print $1 }')"
            protectedkeyname="${rootname}_protected"

            keyname="/$partition/$rootname"

            echo "Processing $keyname"
            openssl rsa -$cipher -in $unciphered -out "../protected/"$unciphered"_protected" -passout pass:$keyphrase

            scp -q -i $idfile "../protected/"$unciphered"_protected" $user@$host:/var/tmp/protected-keys/

            # move the file out of the protected dir to sent
            mv "../protected/"$unciphered"_protected" ../sent/

            # import the key
            unciphered_fixed=$(echo "$unciphered" | sed 's/:/\\:/g')

            payload="{\"command\": \"install\", \"name\": \""$protectedkeyname"\", \"security-type\": \"password\", \"from-local-file\": \"/var/tmp/protected-keys/"$unciphered"_protected\" }"

            url="https://${host}/mgmt/tm/sys/crypto/key"
            auth_header="Authorization: $auth_token"
            content_type="Content-Type: application/json"

            res=$(curl -sw '%{http_code}' --output /dev/null -k --location --request POST $url --header "$auth_header" --header "$content_type" --data-raw "$payload" )

            # FIXED: test if call was successful
            if [ $res -eq 200 ]
            then
                url="https://$host/mgmt/tm/ltm/profile/client-ssl/"

                clientprofiles=""
                content=$(curl -s -k --location --request GET $url --header "$auth_header" --data-raw '')

                clientprofiles=$(echo "${content}" | jq -r --arg keyname "$keyname"  '.items[] | select(.certKeyChain[].key==$keyname) | .name ' )

                if [ ! -z "$clientprofiles" ]
                then

                    while IFS= read -r clientprofile; do

                        # we have the url already for the profiles, just need to request the specific one we're working with
                        updateurl=$(echo "$url~$partition~$clientprofile")

                        echo "Updating Client Profile $clientprofile with $protectedkeyname"
                        certkeychain=$(echo "${content}" | jq -r --arg profilename "$clientprofile" --arg apicommand "modify" --arg keyname "$keyname" --arg pkn "$protectedkeyname" --arg keyphrase "$keyphrase" '.items[] | select(.name==$profilename) | .certKeyChain[] | (select(.key==$keyname)) | {command, name, appService, cert, chain, usage, key, passphrase} |  .key = $pkn | .passphrase=$keyphrase | .command=$apicommand') 

                        payload=$(echo "{\"certKeyChain\": [ $certkeychain ]}")

                        updateres=$(curl -w '\n%{http_code}' --output /dev/null -s -k --location --request PATCH $updateurl --header "$auth_header"  --header "$content_type" --data-raw "$payload")

                        if [$updateres -ne 200# ]
                        then
                            updateres=(${updateres[@]})
                            code=${updateres[-1]}
                            body=${updateres[@]::${#updateres[@]}-1}
                            echo "Unsuccessful update: $clientprofile with $protectedkeyname, result $code"
                        fi 

                    done <<< "$clientprofiles"
                else
                    echo "Unprotected Key ($keyname) was not used in any Client SSL Profiles"
                fi

                # Client SSL Profiles - replace any "proxyCaKey" entries
                proxycaprofiles=$(echo "${content}" | jq -r --arg keyname "$keyname"  '.items[] | select(.proxyCaKey==$keyname) | .name ' )

                if [ ! -z "$proxycaprofiles" ]
                then

                    while IFS= read -r proxycaprofile; do

                        # we have the url already for the profiles, just need to request the specific one we're working with
                        updateurl=$(echo "$url~$partition~$proxycaprofile")

                        echo "Updating server Profile $proxycaprofile with $protectedkeyname for Keys"
                        # set up the update request
                        payload=$(echo "${content}" | jq -r --arg keyname "$keyname" --arg newkey "$protectedkeyname" --arg apicommand "modify" --arg profilename "$proxycaprofile" --arg keyphrase "$keyphrase" '.items[] | select(.key==$keyname) | {command, c3dCaCert, c3dCaKey, cert, chain, key, passphrase } | .command=$apicommand | .key=$newkey | .passphrase=$keyphrase'  )

                        updateres=$(curl -w '%{http_code}' --output /dev/null -s -k --location --request PATCH $updateurl --header "$auth_header"  --header "$content_type" --data-raw "$payload")
                        
                        if [ $updateres -ne 200 ]
                        then
                            updateres=(${updateres[@]})
                            code=${updateres[-1]}
                            body=${updateres[@]::${#updateres[@]}-1}
                            echo "Unsuccessful update: $proxycaprofile with $protectedkeyname, result $code"
                        fi 

                    done <<< "$serverprofiles"
                else
                    echo "Unprotected Key ($unciphered) was not used in any Server SSL Profiles as a Key"
                fi

                # Server SSL Profiles
                url="https://$host/mgmt/tm/ltm/profile/server-ssl/"
                serverprofiles=$(curl -s -k --location --request GET $url --header "$auth_header" --data-raw '' | jq -r --arg kname "{$partition}/{$unciphered}" '.items[] | if .key == $kname then .name else empty end ')

                serverprofiles=""
                content=$(curl -s -k --location --request GET $url --header "$auth_header" --data-raw '')

                #Server SSL Profiles - replace any "key" entries
                serverprofiles=$(echo "${content}" | jq -r --arg keyname "$keyname"  '.items[] | select(.key==$keyname) | .name ' )

                if [ ! -z "$serverprofiles" ]
                then

                    while IFS= read -r proxycaprofile; do

                        # we have the url already for the profiles, just need to request the specific one we're working with
                        updateurl=$(echo "$url~$partition~$proxycaprofile")

                        echo "Updating server Profile $proxycaprofile with $protectedkeyname for Keys"
                        # set up the update request
                        payload=$(echo "${content}" | jq -r --arg keyname "$keyname" --arg newkey "$protectedkeyname" --arg apicommand "modify" --arg profilename "$proxycaprofile" --arg keyphrase "$keyphrase" '.items[] | select(.key==$keyname) | {command, c3dCaCert, c3dCaKey, cert, chain, key, passphrase } | .command=$apicommand | .key=$newkey | .passphrase=$keyphrase'  )

                        updateres=$(curl -w '%{http_code}' --output /dev/null -s -k --location --request PATCH $updateurl --header "$auth_header"  --header "$content_type" --data-raw "$payload")
                        
                        if [ $updateres -ne 200 ]
                        then
                            updateres=(${updateres[@]})
                            code=${updateres[-1]}
                            body=${updateres[@]::${#updateres[@]}-1}
                            echo "Unsuccessful update: $proxycaprofile with $protectedkeyname, result $code"
                            message=$(echo $body)
                            echo "$updateres[@]"
                            echo "$updateres"
                        fi 

                    done <<< "$serverprofiles"
                else
                    echo "Unprotected Key ($unciphered) was not used in any Server SSL Profiles for C3DKeys"
                fi

                #Server SSL Profiles - replace any "c3dCakey" entries
                serverprofiles=$(echo "${content}" | jq -r --arg keyname "$keyname"  '.items[] | select(.c3dCakey==$keyname) | .name ' )

                if [ ! -z "$serverprofiles" ]
                then

                    while IFS= read -r proxycaprofile; do

                        # we have the url already for the profiles, just need to request the specific one we're working with
                        updateurl=$(echo "$url~$partition~$proxycaprofile")

                        echo "Updating server Profile $proxycaprofile with $protectedkeyname for c3dCaKeys"
                        # set up the update request
                        payload=$(echo "${content}" | jq -r --arg keyname "$keyname" --arg newkey "$protectedkeyname" --arg apicommand "modify" --arg profilename "$proxycaprofile" --arg keyphrase "$keyphrase" '.items[] | select(.key==$keyname) | {command, c3dCaCert, c3dCaKey, cert, chain, key, passphrase } | .command=$apicommand | .c3dCakey=$newkey | .passphrase=$keyphrase'  )

                        updateres=$(curl -w '%{http_code}' --output /dev/null -s -k --location --request PATCH $updateurl --header "$auth_header"  --header "$content_type" --data-raw "$payload")
                        
                        if [ $updateres -ne 200 ]
                        then
                            updateres=(${updateres[@]})
                            code=${updateres[-1]}
                            body=${updateres[@]::${#updateres[@]}-1}
                            echo "Unsuccessful update: $proxycaprofile with $protectedkeyname, result $code"
                        fi 

                    done <<< "$serverprofiles"
                else
                    echo "Unprotected Key ($unciphered) was not used in any Server SSL Profiles for ProxyCAs"
                fi

            else
                res=(${res[@]})
                code=${res[-1]}
                body=${res[@]::${#res[@]}-1}
                echo "Failed to install new protected key with result: $code and $body"
            fi
            echo ""
        done

    # remove files from temp folder on BIG-IP
    echo "Removing temporary files from the BIG-IP"
    ssh -i $idfile $user@$host "rm -rf $remotedir/*"

    echo "Complete!!"

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