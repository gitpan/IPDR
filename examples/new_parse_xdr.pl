#!/usr/local/bin/perl

use strict;
use IPDR::Process::XDR;

my $ipdr_client = new IPDR::Process::XDR (
	[
	Format => 'XML',
	DataHandler => \&display_data,
	SourceFile => 'source_file.xdr'
	]
	);

$ipdr_client->decode_file();

exit(0);

sub display_data
{
my ( $data ) = shift;
my ( $self ) = shift;

foreach my $sequence ( sort { $a<=>$b } keys %{$data} )
    {
    print "Sequence  is $sequence\n";
    foreach my $attribute ( keys %{${$data}{$sequence}} )
	{
	print  "Sequence  is '$sequence' attribute is '$attribute' value is '${$data}{$sequence}{$attribute}'\n";
	}
    }
}
