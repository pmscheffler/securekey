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
    cd $dir/incoming
    for unciphered in *; do openssl rsa -$cipher -in $unciphered -out ../protected/{$unciphered}_protected -passout pass:$keyphrase ; done

    cd ..

    # push the protected files to the BIG-IP
    # note that you need to put the files where the BIG-IP can reference them

    # create temp dir to put files into on BIG-IP
    ssh -i $idfile $user@$host "mkdir -p $remotedir"

    scp -q -i $idfile protected/* $user@$host:/var/tmp/protected-keys/
    
    # send files via tmsh commands in the api
        

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