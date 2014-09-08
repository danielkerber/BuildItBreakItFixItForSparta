import argparse
import sys
import os.path
import subprocess
import hashlib
from Crypto.Cipher import AES
import json
import re

HARDCODED_STRING = "e6f5bfbaae"
HARDCODED_STRING_LENGTH = len(HARDCODED_STRING)
HARDCODED_STRING_LENGTH_PLUS_32 = HARDCODED_STRING_LENGTH + 32
GALLERY_LOCATION = -1
OUT_OF_GALLERY_LOCATION = -2

def handle_single_command(options):
    log_path = options.log

    if (log_path == None) or (re.match('^[\w_]+$', log_path) == None):
        # we need the last argument to be the path to log
        return -1

    token = options.token
    if token == None or not token.isalnum():
        # need to submit a token and be alpha numeric
        return -1

    # verify exactly one emp/guest
    employee_name = options.employee_name
    guest_name = options.guest_name
    if ((employee_name and guest_name) or (not employee_name and not guest_name)):
        return -1
    # verify alphabetical of emp/guest
    if (employee_name and not employee_name.isalpha()) or (guest_name and not guest_name.isalpha()):
        return -1
    
    # verify exactly one of arrive/depart
    arrival = options.arrival
    departure = options.departure
    if ((arrival and departure) or (not arrival and not departure)):
        return -1
    # verify room id is positive
    room_id = options.room_id
    if (room_id and room_id < 0):
        return -1
    # verify no B option here -- also check in the handle_multiple_commands method
    if options.batch:
        # something went wrong with parsing
        return -1

    # encrypted under the -K option passed in as a 256 hash
    key = hashlib.sha256(token).digest()

    timestamp = options.timestamp
    if (timestamp == None or timestamp < 0):
        return -1

    if os.path.isfile(log_path):
        # appending to an existing log
        f=open(log_path, 'r')
        raw = f.read()
        f.close()

        try:

            obj = AES.new(key, AES.MODE_CFB, raw[:AES.block_size])
            message = obj.decrypt(raw[AES.block_size:])

            if message[:HARDCODED_STRING_LENGTH] != HARDCODED_STRING:
                # token was not correct if it didn't decrypt
                # to the hardcoded string properly
                return -2

            # hsh is sha256 which is 32 string characters
            hsh = message[HARDCODED_STRING_LENGTH:HARDCODED_STRING_LENGTH_PLUS_32]
            data = message[HARDCODED_STRING_LENGTH_PLUS_32:]

            if hsh != hashlib.sha256(data).digest():
                # hsh was not correct, probably somebody
                # mucked the data
                return -2
            data = json.loads(data)
        except:
            # something wasn't formatted properly
            # this is a security error
            return -2

        if data['t'] >= timestamp:
            # timestamps need to increase
            return -1
        data['t'] = timestamp

        if guest_name:
            database = data['g']
            name = guest_name
        else:
            database = data['e']
            name = employee_name

        if departure:
            if not name in database:
                # no data on user
                # a user not in our system can't leave
                return -1
            if room_id != None:
                if database[name]['s'] == room_id:
                    # sucessfully left the room
                    # set status
                    database[name]['s'] = GALLERY_LOCATION
                    # show when that room was left
                    database[name][str(room_id)].append(timestamp)
                else:
                    # can't leave a room not currently in
                    return -1
            else:
                if database[name]['s'] == GALLERY_LOCATION:
                    # successfully left the gallery
                    # set status
                    database[name]['s'] = OUT_OF_GALLERY_LOCATION
                    # show when gallery was left
                    database[name]['a'].append(timestamp)
                else:
                    # either in a room or not in gallery, can't leave it
                    return -1
        else:
            # this is an arrival
            if not name in database:
                # no data on user
                if room_id != None:
                    # can't enter a room first
                    return -1
                else:
                    # successfully entered gallery for first time
                    database[name] = {'s': GALLERY_LOCATION, 'a': [timestamp], 'r': ''}
            else:
                if room_id != None:
                    if database[name]['s'] == GALLERY_LOCATION:
                        # successfully entered room
                        # set status
                        database[name]['s'] = room_id
                        # set new room got to
                        if database[name]['r'] == '':
                            database[name]['r'] = str(room_id)
                        else:
                            database[name]['r'] += ',%s' % room_id

                        # show when room was entered
                        try:
                            # add to list to log when user in room
                            database[name][room_id].append(timestamp)
                        except KeyError:
                            # create new dictionary to log when user in room
                            database[name][room_id] = [timestamp]
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
                        database[name]['a'].append(timestamp)

    else:
        # this is a new log
        data = {}
        data['t'] = timestamp
        data['g'] = {}
        data['e'] = {}

        if departure or room_id != None:
            # this is the first entry, has to be an arrival
            # can't enter a room first
            return -1
        if guest_name:
            data['g'][guest_name] = {'s': GALLERY_LOCATION, 'a': [timestamp], 'r': ''}
        else:
            data['e'][employee_name] = {'s': GALLERY_LOCATION, 'a': [timestamp], 'r': ''}

    result = json.dumps(data, separators=(',',':'))

    # encrypt the json result
    f=open(log_path, 'w')
    nonce = os.urandom(AES.block_size)
    # the hardcoded string checks the validity of the token
    # the hash preserves integrety by being able to check it
    # on decrypt.  Security ensured with encryption and this MAC
    message = HARDCODED_STRING + hashlib.sha256(result).digest() + result

    # first line of file is unencrypted nonce, 2nd line is encrypted
    # first line of encrypted is the hardcoded string, rest is log data
    f.write(nonce + AES.new(key, AES.MODE_CFB, nonce).encrypt(message))
    f.close()

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
        subprocess.call([sys.argv[0]] + line.split())
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
