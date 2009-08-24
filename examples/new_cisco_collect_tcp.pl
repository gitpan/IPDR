#!/usr/local/bin/perl

use strict;
use IPDR::Collection::Cisco;

my $ipdr_client = new IPDR::Collection::Cisco (
			[
			VendorID => 'IPDR Client',
			ServerIP => '80.194.79.218',
			ServerPort => '5000',
			Timeout => 2,
			Type => 'docsis',
			XMLDirectory =>'/home/poller/',
			DataHandler => \&display_data,
			]
			);

# Check for data from the IPDR server.
my $status = $ipdr_client->connect();

if ( !$status )
	{
	print "Status was '".$ipdr_client->return_status()."'\n";
	print "Error was '".$ipdr_client->return_error()."'\n";
	exit(0);
	}

$ipdr_client->check_data_available();

exit(0);

sub display_data
{
my ( $remote_ip ) = shift;
my ( $remote_port ) = shift;
my ( $data ) = shift;

print "display Data is '$data'\n";

foreach my $sequence ( sort { $a<=> $b } keys %{$data} )
	{
	print "Sequence  is '$sequence'\n";
	foreach my $attribute ( keys %{${$data}{$sequence}} )
		{
		print "Sequence '$sequence' attribute '$attribute' value '${$data}{$sequence}{$attribute}'\n";
		}
	}

}

