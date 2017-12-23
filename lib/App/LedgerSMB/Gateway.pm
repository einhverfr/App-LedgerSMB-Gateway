package App::LedgerSMB::Gateway;
use App::LedgerSMB::Auth qw(authenticate);
use App::LedgerSMB::Gateway::Internal;
use App::LedgerSMB::Gateway::Quickbooks;
use App::LedgerSMB::Gateway::MyOB;
use App::LedgerSMB::Gateway::IFS;
use Dancer;

set environment => 'development';

our $VERSION = '0.1';

=head1 NAME

App::LedgerSMB::Gateway - Base routines for the LSMB Gateway

=head1 SYNOPSIS

  sanitize($datastruct);
  my $lsmbform = new_form($dbh, $struct);

=head1 ROUTINES

=head2 sanitize

Walks through the keys of a hashref and converts them to the db-friendly
forms if they have a to_db method.

=cut

sub sanitize{
   my ($ref) = @_;
   for my $k (keys %$ref){
       if (ref $ref->{$k}){
	  $ref->{$k}  = $ref->{$k}->to_db if eval { $ref->{$k}->can('to_db') };
      }
   }
}

=head2 new_form($db_handle, $hashref)

Takes a database handle and a hash ref and returns a LSMB Form object with the same
characteristics.

=cut

sub new_form {
   my ($db, $struct) = @_;
   $struct ||= {};
   my $form = bless {}, 'Form';
   $form->{dbh} = $db->connect;
   $form->{$_} = $struct->{$_} for keys %$struct; 
   return $form;
}


1;
