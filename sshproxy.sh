#!/bin/bash

# Need some descriptive text, copyright and license

progname=`basename $0`

# Save tty state for trap function below
original_tty_state=$(stty -g)

tmpkey=''
tmpcert=''
pw=''

# Default values
id=nersc			# Name of key file
user=$USER			# Username
sshdir=~/.ssh			# SSH directory
scope="default"			# Default scope
url="sshproxy.nersc.gov"	# hostname for reaching proxy

#############
# Functions
#############

# Error(error string, ...)
# 
# prints out error string.  Joins multiple arguments with ": "


Error () {

	# Slightly complicated print statement so that output consists of
	# arguments joined with ": " 

	printf "$progname: %s" "$1" 1>&2
	shift
	printf ': %s' "$@" 1>&2
	printf "\n" 1>&2
}

# Bail(exit code, error string, ...)
# 
# prints out error string and exits with given exit code

Bail () {
	# get exit code
	exitcode=$1
	shift

	Error "$@"

	# restore terminal to original state, in case we're interrupted
	# while reading password

	stty $original_tty_state

	# Go bye-bye
	exit $exitcode
}


# Cleanup()
#
# Cleans up temp files on exit

Cleanup () {
	for f in "$tmpkey" "$tmpcert"
	do
		if [[ "$f" != "" && -e "$f" ]]; then
			/bin/rm -f "$f"
		fi
	done
}

# Abort ()
#
# Trap on errors otherwise unhandled, does cleanup and exit(1)

Abort () {
	Bail 255 "Exited on interrupt/error"
}


Usage () {

	if [[ $# -ne 0 ]]; then
		printf "$progname: %s\n\n", "$*"
	fi
	printf "Usage: $progname [-u <user>] [-s <scope>] [-o <filename>] [-U <server URL>]\n"
	printf "\n"
	printf "\t -u <user>\tSpecify remote username (default: $user)\n"
	printf "\t -s <scope>\tSpecify scope (default: '$scope')\n"
	printf "\t -U <URL>\tSpecify alternate URL for sshproxy server (generally only used for testing purposes)\n"
	printf "\n"
	
	exit 0
}

#############
# Actual code starts here...
#############

# Make sure we cleanup on exit

trap Cleanup exit
trap Abort int kill term hup pipe abrt


# for command-line arguments.  In reality, not all of these get used,
# but here for completeness
opt_scope=''	# -s
opt_url=''	# -U
opt_user=''	# -u
opt_out=''	# -o

# Process getopts.  See Usage() above for description of arguments

while getopts "hs:k:U:u:o:" opt; do
	case ${opt} in

		h )
			Usage
		;;

		s )
			opt_scope=$OPTARG
			scope=$opt_scope
		;;

		U )
			url=$OPTARG
		;;

		u )
			user=$OPTARG
		;;

		o )
			opt_out=$OPTARG
		;;

		\? )
			Usage "Unknown argument"
		;;

		: )
			Usage "Invalid option: $OPTARG requires an argument"
		;;

	esac
done

# If user has specified a keyfile, then use that.
# Otherwise, if user has specified a scope, use that for the keyfile name
# And if it's the default, then use the "id" defined above ("nersc")

if [[ $opt_out != "" ]]; then
	idfile=$opt_out
elif [[ "$opt_scope" != "" ]]; then
	idfile="$sshdir/$scope"
else
	idfile="$sshdir/$id"
fi

certfile="$idfile-cert.pub"

# Have user enter password+OTP.  Curl can do this, but does not
# provide any control over the prompt
#
# N.B. INPWPROMPT variable is used in Bail() above for when password
# prompt is interrupted by ctrl-c.  Otherwise terminal gets left in
# a weird state.

read -p "Enter your password+OTP: " -s pw

# read -p doesn't output a newline after entry
printf "\n"

# Make temp files.  We want them in the same target directory as the
# final keys

tmpdir=`dirname $idfile`
tmpdir="$tmpdir"
tmpkey="$(mktemp $tmpdir/key.XXXXXX)"
tmpcert="$(mktemp $tmpdir/cert.XXXXXX)"

# And get the key/cert
curl -s -S -X POST https://$url/create_pair/$scope/ \
	-o $tmpkey -K - <<< "-u $user:$pw"

# Check for error
if [[ $? -ne 0 ]] ; then
	Bail 1 "Failed." "Curl returned" $?
fi

# Get the first line of the file to check for errors from the
# server

read x < $tmpkey

# Check whether password failed

if [[ "$x" =~ "Authentication failed. Failed login" ]]; then
	Error "The sshproxy server said: $x"
	Bail 2 "This usually means you did not enter the correct password or OTP"
fi

# Check whether the file appears to contain a valid key

if [[ "$x" != "-----BEGIN RSA PRIVATE KEY-----" ]]; then
	Error "Did not get in a proper ssh private key. Output was:"
	cat $tmpkey 1>&2
	Bail 3 "Hopefully that's informative"
fi

# The private key and certificate are all in one file.
# Extract the cert into its own file, and move into place

grep ssh-rsa $tmpkey > $tmpcert \
	&& chmod 600 $tmpkey* \
	&& /bin/mv $tmpkey $idfile \
	&& /bin/mv $tmpcert $certfile

if [[ $? -ne 0 ]]; then
	Bail 4 "An error occured after successfully downloading keys (!!!)"
fi

# And give the user some feedback
printf "Successfully obtained ssh key %s\n" "$idfile"

# A few shenanigans to clean up line formatting
valid=`ssh-keygen -L -f $certfile | grep Valid`
shopt -s extglob
valid=${valid/+( )/}
valid=${valid/Valid/valid}
printf "Key is %s\n" "$valid"
