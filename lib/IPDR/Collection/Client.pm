package IPDR::Collection::Client;

use warnings;
use strict;
use IO::Select;
use IO::Socket;
use Unicode::MapUTF8 qw(to_utf8 from_utf8 utf8_supported_charset);
$SIG{CHLD}="IGNORE";

=head1 NAME

IPDR::Collection::Client - IPDR Collection Client

=head1 VERSION

Version 0.20

=cut

our $VERSION = '0.20';

=head1 SYNOPSIS

This is a IPDR module primarily written to connect and collect data
using IPDR from a Motorola BSR6400 CMTS. Some work is still required.

It is not very pretty code, nor perhaps the best approach for some of
the code, but it does work and will hopefully save time for other people
attempting to decode the IPDR protocol (even using the specification it
is hard work).

An example configuration for Cisco is

    cable metering destination 192.168.1.1 5000 192.168.1.2 4000 1 15 non-secure

The IP addresses and ports specified are those of a collector that
the CMTS will send data to. The Cisco implementation does not provide
all IPDR functionality. Setting up a secure connection is not too difficult
(this release does not support it) from a collector point of view however
the Cisco implementation for secure keys is somewhat painful.
This Cisco module opens a socket on the local server waiting for a connection
from a Cisco router.

An example configuration for Motorola BSR is    

    ipdr enable
    ipdr collector 192.168.1.1 5000 3
    ipdr collector 192.168.1.2 4000 2

The IP addresses and ports specicified are those of a collector that will 
connect to the CMTS. You can have multiple collectors connected but only
the highest priority collector will receive data, all others will received
keep alives. 
The Client module makes a connection to the destination IP/Port specified.

An example on how to use this module is shown below. It is relatively simple 
use the different module for Cisco, all others use Client.

    #!/usr/local/bin/perl

    use strict;
    use IPDR::Collection::Client;

    my $ipdr_client = new IPDR::Collection::Client (
                        [
                        VendorID => 'IPDR Client',
                        ServerIP => '192.168.1.1',
                        ServerPort => '5000',
                        KeepAlive => 60,
                        Capabilities => 0x01,
                        DataHandler => \&display_data,
                        Timeout => 2,
                        ]
                        );

    # We send a connect message to the IPDR server
    $ipdr_client->connect();

    # If we do not connect stop.
    if ( !$ipdr_client->connected )
        {
        print "Can not connect to destination.\n";
        exit(0);
        }

    # We now send a connect message
    $ipdr_client->check_data_available();

    print "Error was '".$ipdr_client->get_error()."'\n";

    exit(0);

    sub display_data
    {
    my ( $remote_ip ) = shift;
    my ( $remote_port ) = shift;
    my ( $data ) = shift;
    my ( $self ) = shift;

    foreach my $sequence ( sort { $a<=>$b } keys %{$data} )
        {
        print "Sequence  is '$sequence'\n";
        foreach my $attribute ( keys %{${$data}{$sequence}} )
                {
                print "Sequence '$sequence' attribute '$attribute'";
		print " value '${$data}{$sequence}{$attribute}'\n";
                }
        }

    }

This is the most basic way to access the data. There are multiple scripts in
the examples directory which will allow you to collect and process the IPDR
data.

=head1 FUNCTIONS

=head2 new

The new construct builds an object ready to used by the rest of the module and
can be passed the following varaibles

    VendorID - This defaults to 'Generic Client' but can be set to any string

    ServerIP - 

         Client: This is the IP address of the destination exporter.
         Cisco: This is the IP address of the local server to receive the data

    ServerPort - 

         Client: This is the port of the destination exporter.
         Cisco: This is the port on the local server which will be used to 
                receive data

    KeepAlive - This defaults to 60, but can be set to any value.
    Capabilities - This defaults to 0x01 and should not be set to much else.
    TimeOut - This defaults to 5 and is passed to IO::Socket (usefulness ?!)
    DataHandler - This MUST be set and a pointer to a function (see example)
    DEBUG - Set at your peril, 5 being the highest value.

An example of using new is

    my $ipdr_client = new IPDR::Collection::Client (
                        [
                        VendorID => 'IPDR Client',
                        ServerIP => '192.168.1.1',
                        ServerPort => '5000',
                        KeepAlive => 60,
                        Capabilities => 0x01,
                        DataHandler => \&display_data,
                        Timeout => 2,
                        ]
                        );

=head2 connect

This uses the information set with new and attempts to connect/setup a 
client/server configuration. The function returns 1 on success, 0
on failure. It should be called with

    $ipdr_client->connect();

=head2 connected

You can check if the connect function succeeded. It should return 0
on not connected and 1 if the socket/connection was opened. It can be
checked with

    if ( !$ipdr_client->connected )
        {
        print "Can not connect to destination.\n";
        exit(0);
        }

=head2 check_data_available

This function controls all the communication for IPDR. It will, when needed,
send data to the DataHandler function. It should be called with

    $ipdr_client->check_data_available();

=head2 ALL OTHER FUNCTIONs

The remaining of the functions should never be called and are considered internal
only. They do differ between Client and Cisco however both module provide the same
generic methods, high level, so the internal workings should not concern the 
casual user.

=cut

sub new {

        my $self = {};
        bless $self;

        my ( $class , $attr ) =@_;

	my ( %template );
	my ( %current_data );
	my ( %complete_decoded_data );
	my ( @handles );

	$self->{_GLOBAL}{'DEBUG'}=0;

        while (my($field, $val) = splice(@{$attr}, 0, 2))
                { $self->{_GLOBAL}{$field}=$val; }

        $self->{_GLOBAL}{'STATUS'}="OK";

	if ( !$self->{_GLOBAL}{'VendorID'} )
		{ $self->{_GLOBAL}{'VendorID'}="Generic Client"; }

	if ( !$self->{_GLOBAL}{'ServerIP'} )
		{ die "ServerIP Required"; }

	if ( !$self->{_GLOBAL}{'ServerPort'} )
		{ die "ServerPort Required"; }

	if ( !$self->{_GLOBAL}{'KeepAlive'} )
		{ $self->{_GLOBAL}{'KeepAlive'}=60; }

	if ( !$self->{_GLOBAL}{'Capabilities'} )
		{ $self->{_GLOBAL}{'Capabilities'} = 0x01; } 

	if ( !$self->{_GLOBAL}{'Timeout'} )
		{ $self->{_GLOBAL}{'Timeout'}=5; }

        if ( !$self->{_GLOBAL}{'DataHandler'} )
                { die "DataHandler Function Must Be Defined"; }

        if ( $self->{_GLOBAL}{'RemoteIP'} )
                { $self->{_GLOBAL}{'RemoteIP'}=""; }

        if ( $self->{_GLOBAL}{'RemotePort'} )
                { $self->{_GLOBAL}{'RemotePort'}=""; }

        if ( $self->{_GLOBAL}{'RemotePassword'} )
                { $self->{_GLOBAL}{'RemotePassword'}=""; }

	$self->{_GLOBAL}{'data_ack'}=0;
	$self->{_GLOBAL}{'ERROR'}="" ;
	$self->{_GLOBAL}{'data_processing'}=0;

	$self->{_GLOBAL}{'template'}= \%template;
	$self->{_GLOBAL}{'current_data'}= \%current_data;
        $self->{_GLOBAL}{'complete_decoded_data'} = \%complete_decoded_data;

        return $self;
}

sub return_keep_alive
{
my ( $self ) = shift;
return $self->{_GLOBAL}{'KeepAlive'};
}

sub construct_capabilities
{
my ( $self ) = shift;
my ( $required_capabilities ) = shift;

my ($set_capabilities);
# This must be a hash pointer, so that we can then
# generate the value required.

my ( %capabilities ) = (
        'STRUCTURE'             =>      0x01,
        'MULTISESSION'          =>      0x02,
        'TEMPLATENEGO'          =>      0x03,
        'REQUESTRESPONSE'       =>      0x04
        );

foreach my $requested ( keys %{$required_capabilities} )
        { $set_capabilities+=$capabilities{$requested}; }
return $set_capabilities;
}

sub create_vendor_id
{
my ($vendor_name) =@_;
my $utf8string = to_utf8({ -string => $vendor_name, -charset => 'ISO-8859-1' });
return $utf8string;
}

sub generate_ipdr_message_header
{
my ( $self ) = shift;
my ( $version ) = shift;
my ( $message_id ) = shift;
my ( $session_id ) = shift;
my ( $length ) = shift;
# now we assume the length given is that of the payload
# we return the header, with the new length in the header.

$message_id = _transpose_message_names($message_id);

# We know the header is 8 long, so we need to add that to 
# the length of the payload size, thus making the total
# correct.

$length+=8;
my ($header) = pack("CCCCN", $version, $message_id, $session_id, 0, $length);
if ($self->{_GLOBAL}{'DEBUG'}>0 )
	{
	print "Version is '$version'\n";
	print "Message type is '"._transpose_message_numbers($message_id)."'\n";
	print "Message length is '$length'\n";
	}
return ($header);
}

sub return_current_type
{
my ( $self ) = shift;
my ( $test ) = $self->{_GLOBAL}{'current_data'};
if ( !$test ) { return ""; }
if ( !${$test}{'Type'} ) { return "NULL"; }
return ${$test}{'Type'};
}

sub decode_message_type
{
my ( $self ) = shift;
$self->{_GLOBAL}{'current_data'}={};
my ( $decode_data ) = $self->{_GLOBAL}{'current_data'};
# First we get the version and type
# version is not important ( but might be later )
# type is the message ID
# session is the current session ID
# flags should always be 0 at the moment
# length is the total message length

my ( $message ) = $self->{_GLOBAL}{'data_received'};

if ( !$message ) { return 0; }
if ( length($message)<8 ) { return 0; }
if ( $self->{_GLOBAL}{'DEBUG'}>0 )
	{ ${$decode_data}{'RAWDATARETURNED'}=$message; }
my ( $version, $type, $session, $flags, $length ) = unpack ("CCCCN",$message);
${$decode_data}{'Version'}=$version;
${$decode_data}{'Type'}=_transpose_message_numbers($type);
${$decode_data}{'Session'}=$session;
${$decode_data}{'Flags'}=$flags;
${$decode_data}{'Length'}=$length;

$self->{_GLOBAL}{'data_processing'}=0;

if ( !${$decode_data}{'Type'} )
	{
	${$decode_data}{'Type'}="";
	}

print "Message type in decoder is '".${$decode_data}{'Type'}."'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
print "Message length in decode is '".${$decode_data}{'Length'}."'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
print "Message length is '".length($message)."'\n" if $self->{_GLOBAL}{'DEBUG'}>0;

if ( length($message)<${$decode_data}{'Length'} )
	{
	print "Data lengths are incorrect skipping data.\n" if $self->{_GLOBAL}{'DEBUG'}>0;
	${$decode_data}{'Type'}="DEAD";
	return 1;
	}

print "Length of data received is '".length( $self->{_GLOBAL}{'data_received'} )."'\n" if $self->{_GLOBAL}{'DEBUG'}>0;

$self->{_GLOBAL}{'data_received'} = substr( $self->{_GLOBAL}{'data_received'}, ${$decode_data}{'Length'},
					length($self->{_GLOBAL}{'data_received'})-(${$decode_data}{'Length'}) );

print "Length of data after new block is '".length( $self->{_GLOBAL}{'data_received'} )."'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
if ( length($message)>${$decode_data}{'Length'} )
	{
	$self->{_GLOBAL}{'data_processing'}=1;
	}

$message=substr($message,8,length($message)-8);

if ( ${$decode_data}{'Type'}=~/^connect_response$/i )
	{
	my ( $caps, $keepalive ) = unpack ( "SN",$message );
	my ( $vendor ) = substr($message,6,length($message)-6);
	${$decode_data}{'Capabilities'}=$caps;
	${$decode_data}{'KeepAlive'}=$keepalive;
	${$decode_data}{'VendorID'}=$vendor;
	if ( $self->{_GLOBAL}{'DEBUG'}>0 )
		{
		print "Connect response decoded.\n";
		foreach my $key ( keys %{$decode_data} )
			{
			next if $key=~/^RAWDATARETURNED$/i;
			next if $key=~/^Next_Message$/i;
			print "Variable is '$key' value is '${$decode_data}{$key}'\n";
			}
		}
	return 1;
	}

if ( ${$decode_data}{'Type'}=~/^template_data$/i )
	{
	my ( $config, $template_flags,$something ) = unpack ( "SCN",$message );
	${$decode_data}{'Template_Config'} = $config;
	${$decode_data}{'Template_Flags'} = $template_flags;
	${$decode_data}{'Template_PreData'} = $something;
	#${$decode_data}{'Template_Data'} = substr($message,7,length($message)-7);
	$self->_extract_template_data( substr($message,7,length($message)-7), $self->{_GLOBAL}{'template'} );
	#$self->_extract_template_data( substr($message,7,length($message)-7), $decode_data );
	if ( $self->{_GLOBAL}{'DEBUG'}>0 )
		{
		print "Template Data response decoded.\n";
                foreach my $key ( keys %{$decode_data} )
                        {
                        next if $key=~/^RAWDATARETURNED$/i;
                        print "Variable is '$key' value is '${$decode_data}{$key}'\n";
                        }
		foreach my $key ( keys %{$self->{_GLOBAL}{'template'}} )
			{
			print "Key is '$key'\n";
			}
		}
	#$self->template_store( $template_info );
	return 1;
	}

if ( ${$decode_data}{'Type'}=~/^session_start$/i )
	{
	my ( $uptime ) = unpack("N",$message); $message = substr($message,4,length($message)-4);
	my ( $records ) = decode_64bit_number($message); $message = substr($message,8,length($message)-8);
	my ( $gap_records ) = decode_64bit_number($message); $message = substr($message,8,length($message)-8);
	my ( $primary, $ack_time, $ack_sequence, $document_id ) = unpack ( "CNNS",$message );

	${$decode_data}{'Uptime'} = $uptime;
	${$decode_data}{'Records'} = $records;
	${$decode_data}{'GapRecords'} = $gap_records;
	${$decode_data}{'Primary'} = $primary;
	${$decode_data}{'AckTime'} = $ack_time;
	${$decode_data}{'AckSequence'} = $ack_sequence;
	${$decode_data}{'DocumentID'} = $document_id;
        if ( $self->{_GLOBAL}{'DEBUG'}>0 )
                {
                print "Session start decoded.\n";
                foreach my $key ( keys %{$decode_data} )
                        {
			next if $key=~/^RAWDATARETURNED$/i;
                        print "Variable is '$key' value is '${$decode_data}{$key}'\n";
                        }
		}
	return 1;
	}

if ( ${$decode_data}{'Type'}=~/^get_sessions_response$/i )
	{
	# There is something odd here, the spec says it should be a short
	# the data returned signifies an int ...
	my ( $request_id ) = unpack ("N",$message );
	${$decode_data}{'SESSIONS_RequestID'} = $request_id;
	${$decode_data}{'SESSIONS_Data'} = substr($message,4,length($message)-4);
	return 1;
	}

if ( ${$decode_data}{'Type'}=~/^data$/i )
	{
	my ( $template_id, $config_id, $flags ) = unpack("SSC",$message);
	$message = substr($message,5,length($message)-5);
	my ( $sequence_num ) = decode_64bit_number($message); $message = substr($message,8,length($message)-8);
	my ( $record_type );
	${$decode_data}{'DATA_TemplateID'}=$template_id;
	${$decode_data}{'DATA_ConfigID'}=$config_id;
	${$decode_data}{'DATA_Flags'}=$flags;
	${$decode_data}{'DATA_Sequence'}=$sequence_num;
	${$decode_data}{'DATA_Data'} = $message;
	print "TemplateID is '${$decode_data}{'DATA_TemplateID'}'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
	print "ConfigID is '${$decode_data}{'DATA_ConfigID'}'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
	print "Flags is '${$decode_data}{'DATA_Flags'}'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
	print "Sequence is '${$decode_data}{'DATA_Sequence'}'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
	#${$decode_data}{'records'}=_decode_data_record( ${$decode_data}{'DATA_Data'} );
	return 1;
	}

if ( ${$decode_data}{'Type'}=~/^session_stop$/i )
	{
	my ( $reason_code ) = unpack ("S", $message ); $message = substr($message,2,length($message)-2);
	my ( $reason , $message ) = _extract_utf8_string ( $message );
	${$decode_data}{'reasonCode'} = $reason_code;
	${$decode_data}{'reason'} = $reason;
        if ( $self->{_GLOBAL}{'DEBUG'}>0 )
                {
                print "SessionStop response decoded.\n";
                foreach my $key ( keys %{$decode_data} )
                        {
                        next if $key=~/^RAWDATARETURNED$/i;
                        print "Variable is '$key' value is '${$decode_data}{$key}'\n";
                        }
                }
	return 1;
	}

if ( ${$decode_data}{'Type'}=~/^error$/i )
	{
	my ( $time, $error_code ) = unpack ("NS",$message ) ; $message = substr($message,6,length($message)-6);
	my ( $reason , $message ) = _extract_utf8_string ( $message );
	${$decode_data}{'timeStamp'} = $time;
	${$decode_data}{'errorCode'} = $error_code;
	${$decode_data}{'reason'} = $reason;
        if ( $self->{_GLOBAL}{'DEBUG'}>0 )
                {
                print "Error response decoded.\n";
                foreach my $key ( keys %{$decode_data} )
                        {
                        next if $key=~/^RAWDATARETURNED$/i;
                        print "Variable is '$key' value is '${$decode_data}{$key}'\n";
                        }
                }
	return 1;
	}

if ( $self->{_GLOBAL}{'DEBUG'}>0 )
	{
	print "Message received '${$decode_data}{'Type'}'\n";
	}

return 0;
}

sub send_disconnect
{
my ( $self ) = shift;
my ( $data ) = shift;
my ( $result ) = $self->send_message( $self->construct_disconnect() );
return $result;
}

sub send_flow_stop
{
my ( $self ) = shift;
my ( $data ) = shift;
my ( $code ) = shift;
my ( $reason ) = shift;
my ( $result ) = $self->send_message( $self->construct_flow_stop($code,$reason) );
return $result;
}

sub send_get_keepalive
{
my ( $self ) = shift;
my ( $data ) = shift;
if ( $self->get_internal_value('data_ack') )
	{
	print "Data ACK is set\n" if $self->{_GLOBAL}{'DEBUG'}>0;
	$self->send_data_ack( 
		$self->get_internal_value('dsn_configID'), 
		$self->get_internal_value('dsn_sequence') 
		);

	# here we need to add the remote sending of the extracted
	# data. More than likely a fork is required so not to stall
	# the collection process. A fork maybe needed anyway as if
	# the dataset exceeds, say 10,000 entries ( easily done )
	# and being processed locally, any data store *may* not be
	# quick enough.
	my $child;
	if ($child=fork)
		{ } elsif (defined $child)
		{
		$self->{_GLOBAL}{'DataHandler'}->(
			$self->{_GLOBAL}{'ServerIP'},
			$self->{_GLOBAL}{'ServerPort'},
			$self->{_GLOBAL}{'complete_decoded_data'},
			$self
			);
		waitpid($child,0);
		exit(0);
		}

	$self->{_GLOBAL}{'complete_decoded_data'}={};
	$self->set_internal_value('data_ack',0);
	$self->{_GLOBAL}{'current_data'}={};
	}

my ( $result ) = $self->send_message( $self->construct_get_keepalive() );
return $result;
}

sub send_get_sessions
{
my ( $self ) = shift;
my ( $data ) = shift;
my ( $result ) = $self->send_message( $self->construct_get_sessions() );
return $result;
}

sub send_data_ack
{
my ( $self ) = shift;
my ( $config_id ) = shift;
my ( $seq_number ) = shift;
print "ACK data config_id is '$config_id' sequence number is '$seq_number'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
my ( $result ) = $self->send_message( $self->construct_data_ack($config_id,$seq_number) );
return $result;
}

sub send_final_template_data_ack
{
my ( $self ) = shift;
my ( $data ) = shift;
my ( $result ) = $self->send_message( $self->construct_final_template_data_ack() );
return $result;
}

sub send_flow_start_message
{
my ( $self ) = shift;
my ( $data ) = shift;
my ( $result ) = $self->send_message( $self->construct_flow_start() );
return $result;
}

sub send_connect_message
{
my ( $self ) = shift;
my $result = $self->send_message( $self->construct_connect_message() );
return $result;
}

sub construct_data_ack
{
my ( $self ) = shift;
my ( $config_id ) = shift;
my ( $sequence ) = shift;
print "Constructed id is '$config_id'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
print "Constructed sequence us '$sequence'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
my ( $message ) = pack("S",$config_id);
my ( $sequence_encode ) = encode_64bit_number($sequence);
$message.=$sequence_encode;
if ( $self->{_GLOBAL}{'DEBUG'}>0 )
	{
	print "Packed message is - " if $self->{_GLOBAL}{'DEBUG'}>0;
	for($a=0;$a<length($message);$a++)
       		{
        	print ord (substr($message,$a,1))." ";
        	}
	print "\n";
	}

my ( $header ) = $self->generate_ipdr_message_header(
                        2,"DATA_ACK",0,length($message));
$header.=$message;
return $header;
}


sub construct_final_template_data_ack
{
my ( $self ) = shift;
my ( $header ) = $self->generate_ipdr_message_header(
                        2,"FINAL_TEMPLATE_DATA_ACK",0,0);
return $header;
}

sub construct_flow_stop
{
my ( $self ) = shift;
my ( $code ) = shift;
my ( $reason ) = shift;
my ( $message ) = pack("S",$code); $message.=$reason;
my ( $header ) = $self->generate_ipdr_message_header(
                        2,"FLOW_STOP",0,length($message));
$header.=$message;
return $header;
}

sub construct_disconnect
{
my ( $self ) = shift;
my ( $header ) = $self->generate_ipdr_message_header(
                        2,"DISCONNECT",0,0);
return $header;
}


sub construct_get_sessions
{
my ( $self ) = shift;
my ( $message ) = pack("S",0);
my ( $header ) = $self->generate_ipdr_message_header(
                        2,"GET_SESSIONS",0,length($message));
$header.=$message;
return $header;
}

sub construct_get_keepalive
{
my ( $self ) = shift;
my ( $header ) = $self->generate_ipdr_message_header(
                        2,"KEEP_ALIVE",0,0);
return $header;
}


sub construct_flow_start
{
my ( $self ) = shift;
if ( !$self->create_initiator_id() )
        { return 0; }
my ( $header ) = $self->generate_ipdr_message_header(
                        2,"FLOW_START",0,0);
return $header;
}

sub construct_connect_message
{
my ( $self ) = shift;

if ( !$self->create_initiator_id() )
	{
	return 0;
	}
# so we know all the below
my ( $message ) = pack("NSNN",
		$self->create_initiator_id(),
		$self->{_GLOBAL}{'LocalPort'},
		$self->{_GLOBAL}{'Capabilities'},
		$self->{_GLOBAL}{'KeepAlive'} );
$message.=$self->{_GLOBAL}{'VendorID'};
my ( $header ) = $self->generate_ipdr_message_header(
			2,"CONNECT",0,length($message));
$header.=$message;

return $header;
}

sub disconnect
{
my ( $self ) = shift;
$self->{_GLOBAL}{'Handle'}->close();
return 1;
}

sub connect
{
my ( $self ) = shift;

if ( !$self->test_64_bit() )
	{
	# if you forgot to run make test, this will clobber
	# your run anyway.
	die '64Bit support not available must stop.';
	}

my $lsn = IO::Socket::INET->new
                        (
                        PeerAddr => $self->{_GLOBAL}{'ServerIP'},
                        PeerPort => $self->{_GLOBAL}{'ServerPort'},
                        ReuseAddr => 1,
                        Proto     => 'tcp',
			Timeout    => $self->{_GLOBAL}{'Timeout'}
                        );
if (!$lsn)
	{
	$self->{_GLOBAL}{'STATUS'}="Failed To Connect";
	$self->{_GLOBAL}{'ERROR'}=$!;
	return 0;
	}

$self->{_GLOBAL}{'LocalIP'}=$lsn->sockhost();
$self->{_GLOBAL}{'LocalPort'}=$lsn->sockport();
$self->{_GLOBAL}{'Handle'} = $lsn;
$self->{_GLOBAL}{'Selector'}=new IO::Select( $lsn );
$self->{_GLOBAL}{'STATUS'}="Success Connected";
return 1;
}

sub connected
{
my ( $self ) = shift;
return $self->{_GLOBAL}{'Selector'};
}

sub send_message
{
my ( $self ) = shift;
my ( $message ) = shift;
if ( !$self->{_GLOBAL}{'Handle'} ) { return 0; }
my ( $length_sent );
eval {
	local $SIG{ALRM} = sub { die "alarm\n" };
	alarm 1;
	$length_sent = syswrite ( $self->{_GLOBAL}{'Handle'}, $message );
	alarm 0;
	};

if ( $@=~/alarm/i )
        { return 0; }

print "Sending message of size '".length($message)."'\n" if $self->{_GLOBAL}{'DEBUG'}>0;

if ( $self->{_GLOBAL}{'DEBUG'}>4 )
	{
	for($a=0;$a<length($message);$a++)
		{
		printf("%02x-", ord(substr($message,$a,2)));
		}
	print "\n";
	}

if ( $length_sent==length($message) )
	{ return 1; }
return 0;
}

sub create_initiator_id
{
my ( $self ) = @_;
my ( $initiator_id ) = $self->_IpQuadToInt( $self->{_GLOBAL}{'LocalIP'} );
return $initiator_id;
}

sub _IpQuadToInt 
{
my ($self)= shift;
my($Quad) = shift; 
if ( !$Quad ) { return 0; }
my($Ip1, $Ip2, $Ip3, $Ip4) = split(/\./, $Quad);
my($IpInt) = (($Ip1 << 24) | ($Ip2 << 16) | ($Ip3 << 8) | $Ip4);
return($IpInt);
}

sub _IpIntToQuad { my($Int) = @_;
my($Ip1) = $Int & 0xFF; $Int >>= 8;
my($Ip2) = $Int & 0xFF; $Int >>= 8;
my($Ip3) = $Int & 0xFF; $Int >>= 8;
my($Ip4) = $Int & 0xFF; return("$Ip4.$Ip3.$Ip2.$Ip1");
}

sub _message_types
{
my ( %messages ) = (
        'FLOW_START'                    => 0x01,
        'FLOW_STOP'                     => 0x03,
        'CONNECT'                       => 0x05,
        'CONNECT_RESPONSE'              => 0x06,
        'DISCONNECT'                    => 0x07,
        'SESSION_START'                 => 0x08,
        'SESSION_STOP'                  => 0x09,
        'KEEP_ALIVE'                    => 0x40,
        'TEMPLATE_DATA'                 => 0x10,
        'MODIFY_TEMPLATE'               => 0x1a,
        'MODIFY_TEMPLATE_RESPONSE'      => 0x1b,
        'FINAL_TEMPLATE_DATA_ACK'       => 0x13,
        'START_NEGOTIATION'             => 0x1d,
        'START_NEGOTIATION_REJECT'      => 0x1e,
        'GET_SESSIONS'                  => 0x14,
        'GET_SESSIONS_RESPONSE'         => 0x15,
        'GET_TEMPLATES'                 => 0x16,
        'GET_TEMPLATES_RESPONSE'        => 0x17,
        'DATA'                          => 0x20,
        'DATA_ACK'                      => 0x21,
        'ERROR'                         => 0x23,
        'REQUEST'                       => 0x30,
        'RESPONSE'                      => 0x31
                );
return \%messages;
}

sub _transpose_message_numbers
{
my ( $message_number ) =@_;
my $messages = _message_types();
my %reverse_pack;
foreach my $message ( keys %{$messages} )
        { $reverse_pack{ ${$messages}{$message} } = $message; }
return $reverse_pack{$message_number};
}

sub _transpose_message_names
{
my ( $message_name ) =@_;
my $messages = _message_types();
return ${$messages}{$message_name};
}

sub _extract_template_data
{
my ( $self ) = shift;
my ( $template_data ) = shift;
my ( $template_extract) = shift;

my ( $record_type );
my ( $record_configuration );
my ( $field_id, $field_count, $field_name, $field_enabled );

while ( length($template_data)>10 )
        {
        my ( $template_id ) = unpack("S",$template_data);
        $template_data=substr($template_data,2,length($template_data)-2);

	print "Template found is '$template_id'\n" if $self->{_GLOBAL}{'DEBUG'}>1;

        ( $record_type, $template_data ) = _extract_utf8_string ( $template_data );
        ( $record_configuration , $template_data ) = _extract_utf8_string ( $template_data );

        ${$template_extract}{'Templates'}{$template_id}{'schemaName'}=$record_type;
        ${$template_extract}{'Templates'}{$template_id}{'typeName'}=$record_configuration;

	print "schemaName found is '$record_type'\n" if $self->{_GLOBAL}{'DEBUG'}>1;
	print "typeName found is '$record_configuration'\n" if $self->{_GLOBAL}{'DEBUG'}>1;

        ( $field_count ) =  unpack("N", $template_data ); $template_data=substr($template_data,4,length($template_data)-4);

        ${$template_extract}{'Templates'}{$template_id}{'fieldCount'}=$field_count;

        for ($a=0;$a<$field_count;$a++)
                {
                my ( $typeid, $fieldid ) = unpack("NN",$template_data);
                $template_data=substr($template_data,8,length($template_data)-8);
                ( $field_name , $template_data ) = _extract_utf8_string ( $template_data );
                ( $field_enabled ) = unpack("C",$template_data);
                $template_data=substr($template_data,1,length($template_data)-1);
                ${$template_extract}{'Templates'}{$template_id}{'fields'}{$a}{'name'}=$field_name;
                ${$template_extract}{'Templates'}{$template_id}{'fields'}{$a}{'typeID'}=$typeid;
                ${$template_extract}{'Templates'}{$template_id}{'fields'}{$a}{'fieldID'}=$fieldid;
                ${$template_extract}{'Templates'}{$template_id}{'fields'}{$a}{'enabled'}=$field_enabled;
		print "Field name '$field_name' type '$typeid' fieldid '$fieldid' enabled '$field_enabled' count '$a'\n"
			if $self->{_GLOBAL}{'DEBUG'}>1;
                }
        }
return 1;
}

sub _extract_utf8_string
{
my ( $data ) = @_;
my ( $string_len ) = unpack("N",$data); $data=substr($data,4,length($data)-4);
my ( $new_string ) = substr($data,0,$string_len);
#print "String length is '$string_len' string is '$new_string'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
if ( ( length($data)-$string_len ) < 0 )
	{
	$data="";
	}
	else
	{
	$data=substr($data,$string_len,length($data)-$string_len);
	}
return ($new_string,$data);
}

sub _extract_ip_string
{
my ( $data ) = @_;
my ( $new_string );
if ( !$data ) { return ("",""); }
( $new_string, $data ) = _extract_int ( $data );
( $new_string ) = _IpIntToQuad ( $new_string );
return ($new_string,$data);
}

sub _extract_int
{
my ( $data ) = @_;
if ( length($data)<4 )
	{
	return ( length($data), $data );
	}
my ( $ip_int ) = unpack("N",$data); $data=substr($data,4,length($data)-4);
return ($ip_int,$data);
}

sub _extract_short
{
my ( $data ) = @_;
my ( $ip_int ) = unpack("C",$data); $data=substr($data,1,length($data)-1);
return ($ip_int,$data);
}

sub _extract_unknown
{
my ( $data, $count ) = @_;
( $count ) = (split(/\_/,$count))[1];
$data=substr($data,$count,length($data)-$count);
return ($data);
}

sub _extract_char
{
my ( $data ) = @_;
my ( $char ) = unpack("C",$data);
$data=substr($data,1,length($data)-1);
return ($char,$data);
}

sub _extract_mac
{
my ( $data ) = @_;
my ( $empty, $empty2, $mac1, $mac2, $mac3, $mac4, $mac5, $mac6 ) = unpack ("CCCCCCCC",$data);
my ( $return_data ) = sprintf("%02x%02x.%02x%02x.%02x%02x",$mac1,$mac2,$mac3,$mac4,$mac5,$mac6);
$data=substr($data,8,length($data)-8);
return ($return_data,$data);
}

sub _extract_long
{
my ( $data ) = @_;
my ( $long ) = decode_64bit_number ( $data );
$data=substr($data,8,length($data)-8);
return ($long,$data);
}

sub _extract_list
{
my ( $self ) = shift;
my ( $data ) = shift;
my ( $string_len ) = unpack ("N",$data);
$data=substr($data,4,length($data)-4);
my ( $ip_list ) = substr($data,0,$string_len);
my ( $returned_list ) = "";
while ( length($ip_list)>0 )
	{
	my $structure = substr($ip_list,0,4);
	if ($self->{_GLOBAL}{'DEBUG'}>0 )
		{
	        for($a=0;$a<length($structure);$a++)
                	{
                	print ord (substr($structure,$a,1))." ";
                	}
		}
	$ip_list = substr($ip_list,4,length($ip_list)-4);
	$returned_list.=ord(substr($structure,0,1)).".".ord(substr($structure,1,1)).".".ord(substr($structure,2,1)).".".ord(substr($structure,3,1)).",";
	}
if ( length($returned_list)>0 )
	{ 
	chop($returned_list); 
	if ($self->{_GLOBAL}{'DEBUG'}>0 )
		{
		print "\n\n$returned_list\n\n";
		}
	}
$data=substr($data,$string_len,length($data)-$string_len);
return ($returned_list,$data);
}

sub template_store
{
my ( $self ) = shift;
my ( $data ) = shift;
$self->{_GLOBAL}{'data_template'} = $data;
}

sub template_return
{
my ( $self ) = shift;
return $self->{_GLOBAL}{'data_template'};
}

sub template_value_definitions
{
my %template_params;

$template_params{33}="network_int";
$template_params{34}="network_int";
$template_params{36}="long";
$template_params{39}="ip_list";
$template_params{40}="string";
$template_params{548}="long";
$template_params{802}="network_ip";
$template_params{1827}="mac";

return %template_params;
}

sub decode_64bit_number
{
# see comments on 64bit stuff.
my ( $message ) =@_;
my ($part1,$part2) = unpack("NN",$message);
$part1 = $part1<<32;
$part1+=$part2;
return $part1;
}

sub encode_64bit_number
{
# It seems Q does not work, well not for me
# and this is the quickest way to fix it.
# You STILL NEED 64 BIT SUPPORT!!
my ( $number ) = @_;
# any bit to 64bit number in.
my($test1) = $number & 0xFFFFFFFF; $number >>= 32;
my($test2) = $number & 0xFFFFFFFF;
my $message = pack("NN",$test2,$test1);
return $message;
}

sub check_data_available
{
my ( $self ) = shift;

$self->send_connect_message();

# Check for data from the IPDR server.
while ( $self->check_data_handles && $self->{_GLOBAL}{'ERROR'}!~/not connected/i )
        {
        $self->get_data_segment();

	while ( $self->{_GLOBAL}{'data_processing'}==1 )
		{

        # If we manage to get some data correctly, decode the message
        # during decoding we may also store information, such as template
        # and data sequencing, however this is done internally to avoid
        # complex code here.
        $self->decode_message_type();

        my $last_message = $self->return_current_type();

	print "Last message was '$last_message'\n" if $self->{_GLOBAL}{'DEBUG'}>0;

	if ( $last_message=~/NULL/i || !$last_message )
		{
		$self->{_GLOBAL}{'data_processing'}=0;
		}

        # If the message is a connect_response, send a flow_start
        if ( $self->return_current_type()=~/^CONNECT_RESPONSE$/i )
                { $self->send_flow_start_message(); }

        # If the message is a template data, store the template
        # and ack the template
        if ( $self->return_current_type()=~/^TEMPLATE_DATA$/i )
                { $self->send_final_template_data_ack(); }

        # If the message is a session_start just send a keep
        # alive.
        if ( $self->return_current_type()=~/^SESSION_START$/i )
                { $self->send_get_keepalive(); }

        # If the message is a keep alive, send one back.
        # This function does a little more, but has been
        # made a wrapper to keep the code clean.
        if ( $self->return_current_type()=~/^KEEP_ALIVE$/i )
                { $self->send_get_keepalive(); }

        # If the message is a data message, process it.
        # This also sends one keepalive upon receipt
        # of the first data segment, so keeping to the
        # specification and allowing DSN generation.
        if ( $self->return_current_type()=~/^DATA$/i )
                {
		$self->decode_data( );
                }

        # If the message is a session_stop, we should probably
        # send a disconnect, but we dont as yet.
	# with session stop you need to send a keepalive, as
	# session stop is not always a disconnect.
        if ( $self->return_current_type()=~/^SESSION_STOP$/i )
                {
		$self->send_get_keepalive();
                #$ipdr_client->{_GLOBAL}{'Selector'}->remove( $ipdr_client->{_GLOBAL}{'Handle'} );
                }

        # If the message is an error message, stop, something
        # went wrong somewhere.
        if ( $self->return_current_type()=~/^ERROR$/i )
                {
                return 0;
                }
		}
        }

return 1;
}

# ***************************************************************

sub check_data_handles
{
my ( $self ) = shift;
my ( @handle ) = $self->{_GLOBAL}{'Selector'}->can_read;
if ( !@handle ) {  $self->{_GLOBAL}{'ERROR'}="Not Connected"; }
$self->{_GLOBAL}{'ready_handles'}=\@handle;
}

sub get_data_segment
{
my ( $self ) = shift;
my ( $header );
my ( $buffer ) = "";
my ( $dataset ) ;

#$self->{_GLOBAL}{'data_received'} = ""; 

my $link;
my ( $version, $type, $session, $flags, $length );
my ( $handles ) = $self->{_GLOBAL}{'ready_handles'};

foreach my $handle ( @{$handles} )
	{ 
	$link = sysread($handle,$buffer,1024);
	if ( !$buffer )
		{
		$handle->close(); return 1;
		}
	print "Read buffer size of '".length($buffer)."'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
	$self->{_GLOBAL}{'data_received'} .=$buffer;
	}
print "Length in buffer is '".length($self->{_GLOBAL}{'data_received'})."'\n" if $self->{_GLOBAL}{'DEBUG'}>0;
$self->{_GLOBAL}{'data_processing'}=1;
}

sub get_error
{
my ( $self ) = shift;
return $self->{_GLOBAL}{'ERROR'};
}

sub get_internal_value
{
my ( $self ) = shift;
my ( $attribute ) = shift;
return $self->{_GLOBAL}{$attribute};
}

sub set_internal_value
{
my ( $self ) = shift;
my ( $attrib ) = shift;
my ( $value ) = shift;
$self->{_GLOBAL}{$attrib}=$value;
}

sub decode_data
{
my ( $self ) = shift;
my ( %template_params ) = template_value_definitions();
my ( $resulting_value ) = "";

my ( $exported_data ) = $self->{_GLOBAL}{'complete_decoded_data'};
my ( $record ) = $self->{_GLOBAL}{'current_data'};
my ( $template ) = $self->{_GLOBAL}{'template'};
my ( $template_id ) = ${$record}{'DATA_TemplateID'};
my ( $data ) = ${$record}{'DATA_Data'};

$self->set_internal_value('dsn_sequence',${$record}{'DATA_Sequence'} );
$self->set_internal_value('dsn_configID',${$record}{'DATA_ConfigID'} );

if ( !$self->get_internal_value('data_ack') )
	{
	$self->set_internal_value('data_ack',1);
	$self->send_message( $self->construct_get_keepalive() );
	}

my ( $int_or_dir ) = unpack("N",$data);

# If you can figure out the first line, better person than I
# All i figured out was 'possibly' direction, but this
# might also be interface number so it has not been added 

$data = substr($data,4,length($data)-4);

#${$template}{'Templates'}{$template_id}{'fields'}{$a}{'name'}=$field_name;

foreach my $variable ( sort {$a<=> $b } keys %{${$template}{'Templates'}{$template_id}{'fields'}} )
	{
	#print "Type id is '${$template}{'Templates'}{$template_id}{'fields'}{$variable}{'typeID'}'\n";
	my $type = $template_params{ ${$template}{'Templates'}{$template_id}{'fields'}{$variable}{'typeID'} };
	if ( $type=~/^string$/i )
		{ ( $resulting_value, $data ) = _extract_utf8_string ( $data ); }
	if ( $type=~/^network_ip$/i )
		{ ( $resulting_value, $data ) = _extract_ip_string ( $data ); }
	if ( $type=~/^network_int$/i )
		{ ( $resulting_value, $data ) = _extract_int ( $data ); }
	if ( $type=~/^unknown_/i )
		{ ( $data ) = _extract_unknown ( $data, $type ); }
	if ( $type=~/^mac$/i )
		{ ( $resulting_value, $data ) = _extract_mac ( $data, $type ); }
	if ( $type=~/^long$/i )
		{ ( $resulting_value, $data ) = _extract_long ( $data ); }
	if ( $type=~/^ip_list$/i )
		{ ( $resulting_value, $data ) = _extract_list ( $self, $data ); }
	${$exported_data}{ ${$record}{'DATA_Sequence'} }{ ${$template}{'Templates'}{$template_id}{'fields'}{$variable}{'name'} }=$resulting_value;
	}
return 1;
}

sub test_64_bit
{
my $self = shift;

my $tester=576466952313524498;

my $origin = $tester;

#print "Tester is '$tester'\n";

my($test1) = $tester & 0xFFFFFFFF; $tester >>= 32;
my($test2) = $tester & 0xFFFFFFFF;

my $message = pack("NN",$test2,$test1);

my ($part1,$part2) = unpack("NN",$message);

$part1 = $part1<<32;
#$part1 & 0xFFFFFFFF;
$part1+=$part2;

if ( $origin!=$part1 )
        {
        return 0;
        }
        else
        {
        return 1;
        }
}


=head1 AUTHOR

Andrew S. Kennedy, C<< <shamrock at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-ipdr-cisco at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=IPDR-Collection-Client>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc IPDR::Collection::Client

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/IPDR-Collection-Client>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/IPDR-Collection-Client>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=IPDR-Collection-Client>

=item * Search CPAN

L<http://search.cpan.org/dist/IPDR-Collection-Client>

=back

=head1 ACKNOWLEDGEMENTS

Thanks to http://www.streamsolutions.co.uk/ for my Flash Streaming Server

=head1 COPYRIGHT & LICENSE

Copyright 2009 Andrew S. Kennedy, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1; # End of IPDR::Collection::Client
