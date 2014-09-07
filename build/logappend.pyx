#!/usr/bin/env python

import argparse
import sys
import os.path
import subprocess
import hashlib
from Crypto.Cipher import AES
import json
import re

HARDCODED_STRING = "e6f5bfbaae81a4496b5489f"
GALLERY_LOCATION = -1
OUT_OF_GALLERY_LOCATION = -2

def handle_options(options, log_data=None):
    if log_data:
        data = json.loads(log_data)
        timestamp = data['t']
        if timestamp >= options.timestamp:
            # timestamps need to increase
            return -1
        data['t'] = options.timestamp

        if options.guest_name:
            database = data['g']
            name = options.guest_name
        else:
            database = data['e']
            name = options.employee_name

        if options.departure:
            if not name in database:
                # no data on user
                # a user not in our system can't leave
                return -1
            if options.room_id != None:
                if database[name]['s'] == options.room_id:
                    # sucessfully left the room
                    # set status
                    database[name]['s'] = GALLERY_LOCATION
                    # show when that room was left
                    database[name][str(options.room_id)].append(options.timestamp)
                else:
                    # can't leave a room not currently in
                    return -1
            else:
                if database[name]['s'] == GALLERY_LOCATION:
                    # successfully left the gallery
                    # set status
                    database[name]['s'] = OUT_OF_GALLERY_LOCATION
                    # show when gallery was left
                    database[name]['a'].append(options.timestamp)
                else:
                    # either in a room or not in gallery, can't leave it
                    return -1
        else:
            # this is an arrival
            if not name in database:
                # no data on user
                if options.room_id != None:
                    # can't enter a room first
                    return -1
                else:
                    # successfully entered gallery for first time
                    database[name] = {'s': GALLERY_LOCATION, 'a': [options.timestamp], 'r': ''}
            else:
                if options.room_id != None:
                    if database[name]['s'] == GALLERY_LOCATION:
                        # successfully entered room
                        # set status
                        database[name]['s'] = options.room_id
                        # set new room got to
                        if database[name]['r'] == '':
                            database[name]['r'] = str(options.room_id)
                        else:
                            database[name]['r'] += ',%s' % options.room_id

                        # show when room was entered
                        try:
                            # add to list to log when user in room
                            database[name][str(options.room_id)].append(options.timestamp)
                        except KeyError:
                            # create new dictionary to log when user in room
                            database[name][str(options.room_id)] = [options.timestamp]
                    else:
                        # user must be in the gallery to enter another room
                        return -1
                else:
                    if database[name]['s'] != OUT_OF_GALLERY_LOCATION:
                        # can't re enter gallery except from outside the gallery
                        return -1
                    else:
                        # sucessfully re entered the gallery
                        database[name]['s'] = GALLERY_LOCATION
                        database[name]['a'].append(options.timestamp)

    else:
        data = {}
        data['t'] = options.timestamp
        data['g'] = {}
        data['e'] = {}


        if options.departure:
            # this is the first entry, has to be an arrival
            return -1
        if options.room_id != None:
            # can't enter a room first
            return -1
        if options.guest_name:
            data['g'][options.guest_name] = {'s': GALLERY_LOCATION, 'a': [options.timestamp], 'r': ''}
        else:
            data['e'][options.employee_name] = {'s': GALLERY_LOCATION, 'a': [options.timestamp], 'r': ''}

    result = json.dumps(data, separators=(',',':'))
    return result

def encrypt_to_file(file_path, data, options, key):
    f=open(file_path, 'w')
    nonce = os.urandom(AES.block_size)
    # the hardcoded string checks the validity of the token
    # the hash preserves integrety by being able to check it
    # on decrypt.  Security ensured with encryption and this MAC
    message = HARDCODED_STRING + hashlib.sha256(data).digest() + data

    obj = AES.new(key, AES.MODE_CFB, nonce)
    ciphertext = obj.encrypt(message)

    # first line of file is unencrypted nonce, 2nd line is encrypted
    # first line of encrypted is the hardcoded string, rest is log data
    f.write(nonce + ciphertext)
    f.close()


def handle_single_command(options):
    log_path = options.log

    if (log_path == None) or (re.match('^[\w_]+$', log_path) == None):
        # we need the last argument to be the path to log
        return -1
    if options.token == None or not options.token.isalnum():
        # need to submit a token and be alpha numeric
        return -1

    # verify exactly one emp/guest
    if ((options.employee_name and options.guest_name) or (not options.employee_name and not options.guest_name)):
        return -1
    # verify alphabetical of emp/guest
    if (options.employee_name and not options.employee_name.isalpha()) or (options.guest_name and not options.guest_name.isalpha()):
        return -1
    
    # verify exactly one of arrive/depart
    if ((options.arrival and options.departure) or (not options.arrival and not options.departure)):
        return -1
    # verify room id is positive
    if (options.room_id and options.room_id < 0):
        return -1
    # verify no B option here -- also check in the handle_multiple_commands method
    if options.batch:
        # something went wrong with parsing
        return -1

    # encrypted under the -K option passed in as a 256 hash
    key = hashlib.sha256(options.token).digest()

    if os.path.isfile(log_path):
        # appending to an existing log
        f=open(log_path, 'r')
        raw = f.read()
        f.close()
        nonce = raw[:AES.block_size]
        ciphertext = raw[AES.block_size:]

        obj = AES.new(key, AES.MODE_CFB, nonce)

        message = obj.decrypt(ciphertext)
        hardcode_attempt = message[:len(HARDCODED_STRING)]        

        if hardcode_attempt != HARDCODED_STRING:
            # token was not correct if it didn't decrypt
            # to the hardcoded string properly
            return -2

        # hsh is sha256 which is 32 string characters
        hsh = message[len(HARDCODED_STRING):len(HARDCODED_STRING) + 32]
        data = message[len(HARDCODED_STRING) + 32:]

        if hsh != hashlib.sha256(data).digest():
            # hsh was not correct, probably somebody
            # mucked the data
            return -2

        # rest of data is json
        result = handle_options(options, data)
        if result == -1:
            return -1

        # encrypt the json result
        encrypt_to_file(log_path, result, options, key)
    else:
        # this is a new log
        result = handle_options(options)
        if result == -1:
            return -1
        encrypt_to_file(log_path, result, options, key)

    # success
    return 0

def handle_multiple_commands(options):
    f = open(options.log, "r")
    for line in f.readlines():
        line = line.strip()
        if "-B" in line:
            # trying to call batch with batch, spec says this is bad
            sys.stderr.write("cannot call batch within batch mode")
            continue
        call = [sys.argv[0]] + line.split()
        subprocess.call(call)
    f.close()
    return 0

parser = argparse.ArgumentParser()
parser.add_argument("-T", type=int, dest="timestamp")
parser.add_argument("-K", dest="token")
parser.add_argument("-E", dest="employee_name")
parser.add_argument("-G", dest="guest_name")
parser.add_argument("-A", dest="arrival", action='store_true')
parser.add_argument("-L", dest="departure", action='store_true')
parser.add_argument("-R", type=int, dest="room_id")
parser.add_argument("-B", dest="batch", action='store_true')
parser.add_argument("log", help='string for log path or batch path')

options = parser.parse_args()
if options.batch:
    try:
        result = handle_multiple_commands(options)
    except:
        # batch should always return 0
        # this could be a file read error or something
        sys.exit(0)
else:
    try:
        result = handle_single_command(options)
    except:
        # logread exited due to an error condition
        # should print invalid and return -1
        result = -1

if result == -2:
    sys.stderr.write("security error")
    sys.exit(-1)
if result == -1:
    sys.stdout.write('invalid')
    sys.exit(-1)

sys.exit(0)

