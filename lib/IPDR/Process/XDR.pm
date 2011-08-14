package IPDR::Process::XDR;

use warnings;
use strict;
use IO::Select;
use IO::Socket;
use IO::Socket::SSL qw(debug3);
use Unicode::MapUTF8 qw(to_utf8 from_utf8 utf8_supported_charset);
use Time::localtime;
use Time::HiRes qw( usleep ualarm gettimeofday tv_interval clock_gettime clock_getres );
use Math::BigInt;
$SIG{CHLD}="IGNORE";

=head1 NAME

IPDR::Process::XDR - IPDR XDR Prcoessing Client

=head1 VERSION

Version 0.41

=cut

our $VERSION = '0.41';

=head1 SYNOPSIS

This is an IPDR module primarily written to process XDR files.

It is not very pretty code, nor perhaps the best approach for some of
the code, but it does work and will hopefully save time for other people
attempting to decode the IPDR/XDR files.

An example on how to use this module is shown below. It is relatively simple 
use the different module for Cisco, all others use Client.

    #!/usr/local/bin/perl

    use strict;
    use IPDR::Process::XDR;

    my $ipdr_client = new IPDR::Process::XDR (
                        [
			DataHandler => \&display_data,
			SourceFile => 'source_file.xdr'
                        ]
                        );

    # Run the decode.
    $ipdr_client->decode_file();

    exit(0);

    sub display_data
    {
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

This is the only way to current access the XDR records.

=head1 FUNCTIONS

=head2 new

The new construct builds an object ready to used by the rest of the module and
can be passed the following varaibles

    DataHandler - This MUST be set and a pointer to a function (see example)
    SourceFile - The filename of the source XDR file.
    DEBUG - Set at your peril, 5 being the highest value.

An example of using new is

    my $ipdr_client = new IPDR::Process::XDR (
                        [
                        DataHandler => \&display_data,
			SourceFile => 'source_file.xdr'
                        ]
                        );

=head2 decode_file

This runs the decode routine.

=head2 ALL OTHER FUNCTIONs

The remaining of the functions should never be called and are considered internal
only. 

XDR File Location http://www.ipdr.org/public/DocumentMap/XDR3.6.pdf

=cut

sub new {

        my $self = {};
        bless $self;

        my ( $class , $attr ) =@_;

	my ( %template );
	my ( %complete_decoded_data );
	my ( %current_data );

	$self->{_GLOBAL}{'DEBUG'}=0;

        while (my($field, $val) = splice(@{$attr}, 0, 2))
                { $self->{_GLOBAL}{$field}=$val; }

        $self->{_GLOBAL}{'STATUS'}="OK";

	if ( !$self->{_GLOBAL}{'Format'} )
		{ $self->{_GLOBAL}{'Format'}="XML"; }

	if ( !$self->{_GLOBAL}{'MACFormat'} )
		{ $self->{_GLOBAL}{'MACFormat'}=1; }

        if ( !$self->{_GLOBAL}{'DataHandler'} )
                { die "DataHandler Function Must Be Defined"; }

        if ( !$self->{_GLOBAL}{'SourceFile'} )
                { die "SourceFile Must Be Defined"; }

	$self->{_GLOBAL}{'data_processing'}=0;

	$self->{_GLOBAL}{'template'}= \%template;
	$self->{_GLOBAL}{'current_data'}= \%current_data;
        $self->{_GLOBAL}{'complete_decoded_data'} = \%complete_decoded_data;

        return $self;
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
( $new_string, $data ) = _extract_int_u ( $data );
( $new_string ) = _IpIntToQuad ( $new_string );
return ($new_string,$data);
}

sub _IpIntToQuad { my($Int) = @_;
my($Ip1) = $Int & 0xFF; $Int >>= 8;
my($Ip2) = $Int & 0xFF; $Int >>= 8;
my($Ip3) = $Int & 0xFF; $Int >>= 8;
my($Ip4) = $Int & 0xFF; return("$Ip4.$Ip3.$Ip2.$Ip1");
}

sub _extract_int_u
{
# This is forced to be 32bits wide.
my ( $data ) = @_;
if ( length($data)<4 )
	{
	return ( length($data), $data );
	}
my ( $ip_int ) = unpack("N",$data); $data=substr($data,4,length($data)-4);
return ($ip_int,$data);
}

sub _extract_boolean
{
my ( $data ) = @_;
my ( $char);
( $char, $data ) = _extract_char($data);
return ($char,$data);
}

sub _extract_double
{
my ( $data ) = @_;
if ( length($data)<8 )
	{
	return ( length($data), $data );
	}
my ( $ip_int ) = unpack("NN",$data); $data=substr($data,8,length($data)-8);
return ($ip_int,$data);
}

sub _extract_float
{
# This is forced to be a single precision float
# the specification makes no reference to the
# float type.
my ( $data ) = @_;
if ( length($data)<4 )
	{
	return ( length($data), $data );
	}
my ( $ip_int ) = unpack("f",$data); $data=substr($data,4,length($data)-4);
return ($ip_int,$data);
}

sub _extract_int
{
my ( $self ) = shift;
my ( $data ) = shift;
if ( length($data)<4 )
	{
	return ( length($data), $data );
	}
my ( $flash_data ) = substr($data,1,4);
if ( $self->{_GLOBAL}{'DEBUG'} == 5 )
	{
	print "data is ".sprintf("%02x%02x%02x%02x",ord(substr($flash_data,1,1)),ord(substr($flash_data,2,1)),ord(substr($flash_data,3,1)),
			ord(substr($flash_data,4,1)) );
	}
if ( $self->{_GLOBAL}{'BigLittleEndian'}==1 )
	{ $flash_data = _reverse_pattern($flash_data); }
if ( $self->{_GLOBAL}{'DEBUG'} == 5 )
	{
	print "data is ".sprintf("%02x%02x%02x%02x",ord(substr($flash_data,1,1)),ord(substr($flash_data,2,1)),ord(substr($flash_data,3,1)),
			ord(substr($flash_data,4,1)) );
	}

my ( $ip_int ) = unpack("I",$flash_data); $data=substr($data,4,length($data)-4);
return ($ip_int,$data);
}

sub _extract_short
{
my ( $data ) = @_;
my ( $ip_int ) = unpack("S",$data); $data=substr($data,2,length($data)-2);
return ($ip_int,$data);
}

sub _extract_short_u
{
my ( $data ) = @_;
my ( $ip_int ) = unpack("S",$data); $data=substr($data,2,length($data)-2);
return ($ip_int,$data);
}

sub _extract_datetimeusec
{
my ( $data ) = @_;

my ($part1,$part2) = unpack("NN",$data);
$part1 = $part1<<32;
$part1+=$part2;

$data=substr($data,8,length($data)-8);

return ($part1, $data);
}

sub _extract_uuid
{
my ( $data ) = @_;

my ($length,$one_o, $one_t, $two_o, $two_t, $three_o, $three_t,
        $four_o, $four_t, $five_o, $five_t, $six_o, $six_t,
        $seven_o, $seven_t, $eight_o, $eight_t) = unpack("NCCCCCCCCCCCCCCCC",$data );

my ($ipv6addr) = sprintf("%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x",
                $one_o, $one_t, $two_t, $two_t,
                $three_o, $three_t, $four_o, $four_t,
                $five_o, $five_t, $six_o, $six_t,
                $seven_o, $seven_t, $eight_o, $eight_t);

$data=substr($data,20,length($data)-20);
return ($ipv6addr,$data);
}

sub _extract_ipaddr
{
my ( $data ) = @_;
my ( $length ) = unpack("N",$data);
my ( $ipaddr ) = "";
if ( $length == 16 )
	{ ( $ipaddr, $data ) = _extract_ipv6addr ( $data ); }

if ( $length == 4 )
	{ ( $ipaddr, $data ) = _extract_ip_string ( $data ); }

return ( $ipaddr , $data );
}

sub _extract_ipv6addr
{
my ( $data ) = @_;

my ($length,$one_o, $one_t, $two_o, $two_t, $three_o, $three_t,
        $four_o, $four_t, $five_o, $five_t, $six_o, $six_t,
        $seven_o, $seven_t, $eight_o, $eight_t) = unpack("NCCCCCCCCCCCCCCCC",$data );

my ($ipv6addr) = sprintf("%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x",
                $one_o, $one_t, $two_t, $two_t,
                $three_o, $three_t, $four_o, $four_t,
                $five_o, $five_t, $six_o, $six_t,
                $seven_o, $seven_t, $eight_o, $eight_t);

$data=substr($data,20,length($data)-20);
return ($ipv6addr,$data);
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

sub _extract_char_u
{
my ( $data ) = @_;
my ( $char ) = unpack("C",$data);
$data=substr($data,1,length($data)-1);
return ($char,$data);
}

sub _extract_mac
{
my ( $self ) = shift;
my ( $data ) = shift;
my ( $return_data ) = "";
my ( $empty, $empty2, $mac1, $mac2, $mac3, $mac4, $mac5, $mac6 ) = unpack ("CCCCCCCC",$data);
if ( $self->{_GLOBAL}{'MACFormat'} == 1 )
	{ ( $return_data ) = sprintf("%02x%02x.%02x%02x.%02x%02x",$mac1,$mac2,$mac3,$mac4,$mac5,$mac6); }
if ( $self->{_GLOBAL}{'MACFormat'} == 2 )
	{ 
	( $return_data ) = sprintf("%02x-%02x-%02x-%02x-%02x-%02x",$mac1,$mac2,$mac3,$mac4,$mac5,$mac6); 
	$return_data=~tr/[a-z]/[A-Z]/; 
	}
$data=substr($data,8,length($data)-8);
return ($return_data,$data);
}

sub _extract_long_u
{
my ( $data ) = @_;
my ( $long ) = decode_64bit_number ( $data );
$data=substr($data,8,length($data)-8);
return ($long,$data);
}

sub _extract_long
{
my ( $data ) = @_;
my ( $long ) = decode_64bit_number ( $data );
$data=substr($data,8,length($data)-8);
return ($long,$data);
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

$template_params{33}="network_int_u";
$template_params{34}="network_int_u";
$template_params{35}="long_u";
$template_params{36}="long_u";
$template_params{37}="float";
$template_params{38}="double";
$template_params{39}="ip_list";
$template_params{40}="string";
$template_params{41}="boolean";
$template_params{42}="byte_u";
$template_params{43}="byte_u";
$template_params{44}="short_u";
$template_params{45}="short_u";

$template_params{290}="network_int_u";
$template_params{548}="long";
$template_params{802}="network_ip";
$template_params{1063}="ipv6addr";
$template_params{1319}="uuid";
$template_params{1571}="datetimeusec";
$template_params{1827}="mac";
$template_params{2087}="ipaddr";

return %template_params;
}

sub decode_64bit_number_u
{
# see comments on 64bit stuff.
my ( $message ) =@_;
my ($part1,$part2) = unpack("NN",$message);
$part1 = $part1<<32;
$part1+=$part2;
return $part1;
}

sub decode_64bit_number
{
# see comments on 64bit stuff.
my ( $message ) =@_;
my ($part1,$part2) = unpack("NN",$message);
if ( !test_64_bit() )
        {
        return (
        Math::BigInt
              ->new("0x" . unpack("H*", pack("N2", $part1, $part2)))
                  );
        }
$part1 = $part1<<32;
$part1+=$part2;
return $part1;
}

#sub decode_64bit_number_u
#{
## see comments on 64bit stuff.
#my ( $message ) =@_;
#my ($part1,$part2) = unpack("NN",$message);
#$part1 = $part1<<32;
#$part1+=$part2;
#return $part1;
#}

sub encode_64bit_number
{
# It seems Q does not work, well not for me
# and this is the quickest way to fix it.
# You STILL NEED 64 BIT SUPPORT!!
my ( $number ) = @_;
if ( !test_64_bit() )
        {
	my $i = Math::BigInt->new($number);
	my $j = Math::BigInt->new($number)->brsft(32);
	return pack('NN', $j, $i );
        }
# any bit to 64bit number in.
my($test1) = $number & 0xFFFFFFFF; $number >>= 32;
my($test2) = $number & 0xFFFFFFFF;
my $message = pack("NN",$test2,$test1);
return $message;
}

#sub encode_64bit_number
#{
## It seems Q does not work, well not for me
## and this is the quickest way to fix it.
## You STILL NEED 64 BIT SUPPORT!!
#my ( $number ) = @_;
## any bit to 64bit number in.
#my($test1) = $number & 0xFFFFFFFF; $number >>= 32;
#my($test2) = $number & 0xFFFFFFFF;
#my $message = pack("NN",$test2,$test1);
#return $message;
#}

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

sub decode_file
{
my ( $self ) = shift;
my ( $buffer ) = "";
my ( $input )= "";
my ( $running ) = 1;
my ( $start ) = 0;
my ( $len ) = 0;
my ( $string ) = "";
my ( $resulting_value ) = "";
my ( $number_of_fields ) = 0;
my ( $record_count ) = 0;
my ( %template_params ) = template_value_definitions();
my ( %template );

my ( $filename ) = $self->{_GLOBAL}{'SourceFile'};

if ( open (__FILE,"<$filename") )
	{

while (($len = sysread(__FILE, $input, 4096)) > 0)
        {
        $running=1;
        $buffer.=$input;
        if ( $start ==0 )
                {
                my ($header, $first ) = unpack ("NS",$buffer);
                $buffer = substr($buffer,6,length($buffer)-6);
                # Header appears to be 6 bytes in length
                #print "Header is '$header' first '$first'\n";
		$template{'info'}{'template_id'} = $first;
                # Extract document URI
                ($string,$buffer) = _extract_utf8_string($buffer);
		$template{'info'}{'docID'} = $string;
                #print "String is '$string'\n";
                ($string,$buffer) = _extract_utf8_string($buffer);
       		$template{'info'}{'docInfo'} = $string;
		#print "String is '$string'\n";

                ($number_of_fields ) = unpack("N",$buffer);

                $buffer = substr($buffer,4,length($buffer)-4);

                for ($a =0 ; $a<$number_of_fields; $a ++ )
                        {
                        my ( $part1, $real_type, $fieldnum ) = unpack ("nnN",$buffer);
                        $buffer = substr($buffer,8,length($buffer)-8);
                        #print "Part1 is '$part1' type is '$real_type' fieldnum is '$fieldnum'\n";
                        my ($type) = $template_params{$real_type};
                        #print "Real Type is '$type'\n";
                        ( $resulting_value, $buffer ) = _extract_utf8_string ( $buffer );
                        my ( $flag ) = unpack("C",$buffer);
                        $buffer = substr($buffer,1,length($buffer)-1);

                        $template{'fields'}{$fieldnum}{'name'} = $resulting_value;
                        $template{'fields'}{$fieldnum}{'type'} = $type;
                        $template{'fields'}{$fieldnum}{'inuse'} = $flag;
                        }

                #print "Number of fields is '$number_of_fields'\n";
                for ( my $field = 1; $field <($number_of_fields+1); $field++ )
                        {
                        #print "Key is '$field' name is '$template{'fields'}{$field}{'name'}' type is '$template{'fields'}{$field}{'type'}' in use '$template{'fields'}{$field}{'inuse'}'\n";
                        }
                $start=1;

                }
        # So now we have the template

#       my ( $record_len ) = unpack("N",$buffer);

        #print "Record length is '$record_len' size is '".length($buffer)."'\n";

        while ( $running == 1 )
                {

                if ( length($buffer)<=4 )
                        {
                        $running=0;
                        next;
                        }

                 my ( $record_len ) = unpack("N",$buffer);

                if ( length($buffer)<$record_len )
                        {
                        #print "Record len1 is '$record_len' buffer size is '".length($buffer)."'\n";
                        $running=0;
                        next;
                        }

                #print "Size of buffer is '".length($buffer)."'\n";

                $buffer = substr($buffer,4,length($buffer)-4);

                #print "Record sisze is lower than remainder buffer.\n";

		my %xdr_record;

		$record_count++;

                for ( my $field = 1; $field <($number_of_fields+1); $field++ )
                        {
                        $resulting_value="";
                        my ($type) = $template{'fields'}{$field}{'type'};

        if ( $type=~/^string$/i )
                { ( $resulting_value, $buffer ) = _extract_utf8_string ( $buffer ); }
        if ( $type=~/^network_ip$/i )
                { ( $resulting_value, $buffer ) = _extract_ip_string ( $buffer ); }
        if ( $type=~/^network_int_u$/i )
                { ( $resulting_value, $buffer ) = _extract_int_u ( $buffer ); }
        if ( $type=~/^network_int$/i )
                { ( $resulting_value, $buffer ) = _extract_int ( $buffer ); }
        if ( $type=~/^unknown_/i )
                { ( $buffer ) = _extract_unknown ( $buffer, $type ); }
        if ( $type=~/^mac$/i )
                { ( $resulting_value, $buffer ) = $self->_extract_mac ( $buffer ); }
        if ( $type=~/^long$/i )
                { ( $resulting_value, $buffer ) = _extract_long ( $buffer ); }
        if ( $type=~/^long_u$/i )
                { ( $resulting_value, $buffer ) = _extract_long_u ( $buffer ); }
        if ( $type=~/^float$/i )
                { ( $resulting_value, $buffer ) = _extract_float ( $buffer ); }
        if ( $type=~/^double$/i )
                { ( $resulting_value, $buffer ) = _extract_double ( $buffer ); }
        if ( $type=~/^boolean$/i )
                { ( $resulting_value, $buffer ) = _extract_boolean ( $buffer ); }
        if ( $type=~/^byte$/i )
                { ( $resulting_value, $buffer ) = _extract_char ( $buffer ); }
        if ( $type=~/^byte_u$/i )
                { ( $resulting_value, $buffer ) = _extract_char_u ( $buffer ); }
        if ( $type=~/^short$/i )
                { ( $resulting_value, $buffer ) = _extract_short ( $buffer ); }
        if ( $type=~/^short_u$/i )
                { ( $resulting_value, $buffer ) = _extract_short_u ( $buffer ); }
        if ( $type=~/^ipv6addr$/i )
                { ( $resulting_value, $buffer ) = _extract_ipv6addr ( $buffer ); }
        if ( $type=~/^uuid$/i )
                { ( $resulting_value, $buffer ) = _extract_uuid ( $buffer ); }
        if ( $type=~/^datetimeusec$/i )
                { ( $resulting_value, $buffer ) = _extract_datetimeusec ( $buffer ); }
        if ( $type=~/^ipaddr$/i )
                { ( $resulting_value, $buffer ) = _extract_ipaddr ( $buffer ); }
        if ( $type=~/^ip_list$/i )
        { ( $resulting_value, $buffer ) = $self->_extract_list ( $buffer); }


                        #print "Resulting number '$template{'fields'}{$field}{'name'}' value '$resulting_value'\n";

			$xdr_record{$record_count}{$template{'fields'}{$field}{'name'}} = $resulting_value;


                        }

                $self->{_GLOBAL}{'DataHandler'}->(
                       	\%xdr_record,
                       	$self
                       	);

		# Not sure about a memory leak here.

                }
        #print "Exit buffer size is '".length($buffer)."'\n";


        }

close (__FILE);
	}
return 1;
}

sub _extract_list
{
my ( $self ) = shift;
my ( $data ) = shift;

my ( $string_len ) = 0;

( $string_len ) = unpack ("N",$data);
$data=substr($data,4,length($data)-4);

# Remove the list data and return
#
my ( $returned_list ) = "";

        if ( $string_len%2 > 0 )
                {
                }
                else
                {
                # We know we have a good data length so now we decode it
                # we do that too.
                for ( $a=0;$a<$string_len; $a+=2 )
                        {
                        my $partial = substr($data,$a,2);
                        if ( length($partial)==2)
                                {
                                my ($unpp) = unpack("n",$partial);
                                $returned_list .=$unpp.",";
                                }
                                else
                                {
                                }
                        }
                }

if ( length($returned_list)>0 )
        {
        chop($returned_list);
        }

$data=substr($data,$string_len,length($data)-$string_len);
return ($returned_list,$data);
}

sub test_64_bit
{
my $self = shift;

my $tester=576466952313524498;

my $origin = $tester;

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
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=IPDR-Process-XDR>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc IPDR::Process::XDR

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/IPDR-Process-XDR>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/IPDR-Process-XDR>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=IPDR-Process-XDR>

=item * Search CPAN

L<http://search.cpan.org/dist/IPDR-Process-XDR>

=back

=head1 ACKNOWLEDGEMENTS

Thanks to http://www.streamsolutions.co.uk/ for my Flash Streaming Server

=head1 COPYRIGHT & LICENSE

Copyright 2011 Andrew S. Kennedy, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1; # End of IPDR::Process::XDR
