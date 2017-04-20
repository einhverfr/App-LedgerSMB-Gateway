package App::LedgerSMB::Gateway;
use App::LedgerSMB::Auth qw(authenticate);
use App::LedgerSMB::Gateway::Internal;
use App::LedgerSMB::Gateway::Quickbooks;
use App::LedgerSMB::Gateway::IFS;
use JSON;

our $VERSION = '0.1';



sub sanitize{
   my ($ref) = @_;
   for my $k (keys %$ref){
       if (ref $ref->{$k}){
	  $ref->{$k}  = $ref->{$k}->to_db if eval { $ref->{$k}->can('to_db') };
      }
   }
}

sub new_form {
   my ($db, $struct) = @_;
   $struct ||= {};
   my $form = bless {}, 'Form';
   $form->{dbh} = $db->connect;
   $form->{$_} = $struct->{$_} for keys %$struct; 
   return $form;
}


1;
