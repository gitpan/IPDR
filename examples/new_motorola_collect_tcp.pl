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
		print "Sequence '$sequence' attribute '$attribute' value '${$data}{$sequence}{$attribute}'\n";
		}
	}

}


