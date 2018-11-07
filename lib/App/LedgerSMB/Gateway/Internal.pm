package App::LedgerSMB::Gateway::Internal;
use App::LedgerSMB::Auth qw(authenticate);
#use lib "/home/ledgersmb/LedgerSMB/lib";
use lib "/opt/ledgersmb/";
use Try::Tiny;
use App::LedgerSMB::Gateway::Internal::Locale;
use App::LedgerSMB::Gateway::Internal::Reports;
use LedgerSMB::Sysconfig;
use Log::Log4perl;
use Dancer ':syntax';
use Dancer::HTTP;
use Dancer::Serializer;
use Dancer::Response;
use Dancer::Plugin::Ajax;
use LedgerSMB::App_State;
use LedgerSMB::GL;
use LedgerSMB::AA;
use LedgerSMB::IR;
use LedgerSMB::IS;
use LedgerSMB::IC;
use LedgerSMB::DBObject::Account;
use LedgerSMB::Locale;
use LedgerSMB::Form;
use LedgerSMB::Tax;

# next are for counterparty
use LedgerSMB::Entity::Company;
use LedgerSMB::Entity::Person;
use LedgerSMB::Entity::Credit_Account;
use LedgerSMB::Entity::Person::Employee;
use LedgerSMB::Entity::Payroll::Wage;
use LedgerSMB::Entity::Payroll::Deduction;
use LedgerSMB::Entity::Location;
use LedgerSMB::Entity::Contact;
use LedgerSMB::Entity::Bank;
use LedgerSMB::Entity::Note;
use LedgerSMB::Entity::User;

Log::Log4perl::init(\$LedgerSMB::Sysconfig::log4perl_config);
my $locale = App::LedgerSMB::Gateway::Internal::Locale->new();

use Dancer ':syntax';
prefix '/lsmbgw/0.1/:company/internal';
our $VERSION = '0.1';

get '/gl/:id' => sub { return to_json(get_gl(param('id'))) };

=head1 NAME

App::LedgerSMB::Gateway::Internal - Internal version-independent interface
for LSMB-native interaction.

=head1 URLS AND FUNCTIONS

In all urls, :company is to be replaced with the company db name.

Other parameters are described in the function immediately following.

=head2 GET /lsmbgw/0.1/:company/internal/gl/:id

=head2 get_gl(int id)

Takes in an int, returns a hashref in the following structure, or
nothing if gl not found.

=over

=item reference

The reference document number, unique per general journal entry.

=item description

A description of the transaction (free-form)

=item postdate

The date (yyyy-mm-dd format) when the transacction was posted.

=item lineitems

List of line items in the following format:

=over

=item account_number

=item account_description

=item amount

=back

=back

=cut

sub get_gl {
    my ($id) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    my $form = new_form($db);
    $form->{id} = $id;
    GL->transaction({}, $form);
    status 'not_found' unless $form->{reference};
    $form->{dbh}->rollback;
    return {
		reference => $form->{reference},
		postdate  => $form->{transdate},
		description => $form->{description},
		lineitems => [_convert_lines_from_gl($form->{GL})],
    };
}

sub _convert_lines_from_gl {
    my ($lines) = (@_);
    return unless ref $lines;
    return 
    map { {
         account_number => $_->{accno},
	 account_description => $_->{description},
	 amount => $_->{amount},
         reference => $_->{source},
         description => $_->{memo},
         
    } } @$lines;
}

post '/gl/new' => sub { redirect(save_gl(from_json(request->body))) };

=head2 POST /lsmbgw/0.1/:company/internal/gl/new

Body must contain a JSON document with the structure found in the gl retrieval routines above.

=head2 save_gl($hashref)

Takes in a gl in format above and saves it, returning the new id.

=cut

sub save_gl {
    my ($struct) = @_;
    if ((ref $struct) =~ /ARRAY/) {
	  for my $s (@$struct){
	      save_gl($s);
          }
	  return 1;
    }
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    my $form = new_form($db, $struct);
    local $LedgerSMB::App_State::DBH = $form->{dbh};;
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    _unfold_gl_lines($form);
    try {
        GL->post_transaction({}, $form, $locale);
    } catch {
        Dancer::HTTP->status(400);
    };
    $form->{dbh}->commit;
    return $form->{id};
}

sub _unfold_gl_lines{
    my ($struct) = @_;
    my $i = 0;
    my $acinterface = LedgerSMB::DBObject::Account->new(base => $struct);
    my %account = map {$_->{accno} => $_ } $acinterface->list();
    $struct->{transdate} = $struct->{postdate};
    for my $l (@{$struct->{lineitems}}){
        $struct->{"credit_$i"} = $l->{amount};
	$struct->{"accno_id_$i"} = $account{$l->{account_number}}->{id};
	$struct->{"accno_$i"} = $l->{account_number};
	++$i;
    }
    $struct->{rowcount} = $i;
}

=head2 GET /lsmbgw/0.1/:company/internal/salesinvoice/:id

=head2 get_invoice(int $id)

Returns a hashref (or json object document if over url) with the following properties:

=over

=item reference - Invoice identifer

=item postdate - YYYY-MM-DD date if invoice

=item counterparty - Customer account identifier

=item lineitems - array of items containing the following

=over

=item product_number - product SKU

=item description - Long description

=item sellprice - Arbitrary precision decimal per unit

=item quantity - units purchased

=item discount - per unit discount, floating point (20% woudl be 0.2).

=back

=item taxes - array of objects/hashrefs with following properties:

=over

=item account_number

=item amount

=back

=back

=cut

get '/salesinvoice/:id' => sub { return to_json(get_invoice(param('id'))) };
sub get_invoice {
	my ($id) = @_;
	my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
	);
	my $form = new_form($db);
	$form->{id} = $id;
	IS->retrieve_invoice({}, $form);
	_inv_order_calc_taxes($form);
	$form->{dbh}->commit;
        return {
		taxes => $form->{taxes},
		reference => $form->{invnumber},
		postdate  => $form->{transdate},
		description => $form->{description},
		lineitems => _convert_invoice_lines($form->{invoice_details}),
		counterparty => $form->{customernumber},
	};	
}

sub _convert_invoice_lines {
    my ($ref) = @_;
    return [] unless ref $ref;
    return [
    map { {
        product_number => $_->{partnumber},
        quantity => $_->{qty}->bstr,
        sellprice => $_->{sellprice}->bstr,
        discount => $_->{discount}->bstr,	
	description => $_->{description},
    } } @$ref
    ];
}

=head2 POST /lsmbgw/0.1/:company/internal/salesinvoice/new

BODY is JSON document conforming to above GET specification

=head2 save_invoice($hashref)

Takes in a hashref or JSON document (if over URL) in the above specification
and saves it.

=cut

post '/salesinvoice/new' => sub { redirect(save_gl(from_json(request->body))) };
sub save_invoice {
        my ($struct) = @_;
	my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
	);
	my $form = new_form($db, $struct);
	local $LedgerSMB::App_State::DBH = $form->{dbh};;
	local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
	IS->post_invoice({}, $form, $locale);
	$form->{dbh}->commit;
	return $form->{id};
}

get '/ar/:id' => sub { to_json(get_aa(param('id'), 'AR'))};
get '/ap/:id' => sub { to_json(get_aa(param('id'), 'AP'))};

=head2 /lsmbgw/0.1/:company/internal/:arap/:id

=head2 get_aa(int $id, ("AR"|"AP") $arap)

Gets an ar/ap "transaction" and returns it.

In LedgerSMB terms, an AR/AP transaction is tied to amounts
while an invoice is tied to goods and services.  This is 
more or less like an AR or AP equivalent to a GL transaction
than a normal invoice.

$arap may be AR or AP.  $id is any int.

The returned structure has the following fields:

=over

=item reference - Invoice identifier (customer-facing source document)

=item counterparty - Customer or vendor agreement identifier

=item description - Specified title of transaction

=item postdate - date the transaction was posted.

=item lineitems - array of hashref/object with following fields

These are the counter-lines to the AR/AP entry line

=over

=item account_number - account identifier

=item account_desc - account description

=item reference - Optional link to a source document

=item description - Memo for line

=item postdate - date of line item posted (for ex. payment)

=item amount - amount.

=back

=back

Saving these through the internal interfaces is not currently supported.

=cut
 
my %vcmap = (
    'AR' => 'customer',
    'AP' => 'vendor',
);

sub _aa_line_from_internal {
    my ($line) = @_;
    return {
        account_number => $_->{accno},
        account_desc   => $_->{description},
        reference      => $_->{source},
        description    => $_->{memo},
        postdate       => $_->{transdate},
        amount         => $_->{amount}->bstr,
    };
}


sub _aa_line_from_internal {
    my ($line) = @_;
    return {
        account_number => $_->{accno},
        account_desc   => $_->{description},
        reference      => $_->{source},
        description    => $_->{memo},
        postdate       => $_->{transdate},
        amount         => $_->{amount}->bstr,
    };
}


sub get_aa {
	my ($id, $arap) = @_;
	my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
	);
	my $form = new_form($db);
	if ( $arap eq 'AP' ) {
 	    $form->{ARAP} = 'AP';
            $form->{vc}   = 'vendor';
	}  elsif ( $arap eq 'AR' ) {
            $form->{ARAP} = 'AR';
            $form->{vc}   = 'customer';
        }

	$form->{arap} = lc($arap);
	$form->{id} = $id;
	$form->{ARAP} = uc($arap);
	$form->{vc} = $vcmap{$arap};
 	$form->create_links( module => $form->{ARAP},
                             myconfig => {},
	                          vc => $form->{vc},
	                    billing => $form->{vc} eq 'customer');

	$form->{dbh}->commit;
	my @lines = map { _aa_line_from_internal($_) }
	            map { @{$form->{acc_trans}->{$_}} } 
	            keys %{$form->{acc_trans}};
        return {
		reference => $form->{invnumber},
		postdate  => $form->{transdate},
		description => $form->{description},
		lineitems => \@lines,
		counterparty => $form->{"$form->{vc}number"},
	};	
}
post 'ar/new' => sub { redirect(save_aa(from_json(request->body)))};
post 'ap/new' => sub { redirect(save_aa(from_json(request->body)))};

sub save_aa {
    die 'Not implemented';
}

sub get_payment {
}

sub save_payment {
}

get '/coa/:id' => sub { to_json(get_account(param('id'))) };
post '/coa/new' => sub { warning(request->body); redirect(save_account(from_json(request->body))) };

=head2 get /lsmbgw/0.1/:company/internal/coa/:id

Gets an account by numeric id

=head2 get_account(int $id)

Returns a hashref or json object with the following elements:

=over

=item id - int id for account

=item account_number - accountant-facing identifier, alphanumeric

=item description - Dree-form text of account

=item account_type (Asset, Liability, Equity, Income, or Expense)

=back

=head2 post /lsmbgw/0.1/:company/internal/coa/new

=head2 save_account($hashref)

Saves an account with the structure above.

=cut


sub get_account {
    my ($id) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 0 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my ($account) = LedgerSMB::DBObject::Account->get($id);
    status 'not_found' unless $account->{category};
    return _from_account($account);
}

my $category = {
   A => 'Asset',
   L => 'Liability',
   Q => 'Equity',
   E => 'Expense',
   I => 'Income',
};

my $rcategory = { map { $category->{$_} => $_ } keys %$category };

sub _from_account {
    my ($lsmb_act) = @_;
    no warnings;
    return {
        id => $lsmb_act->{id},
	account_number => $lsmb_act->{accno},
        description => $lsmb_act->{description},
        account_type => $category->{$lsmb_act->{category}},
        
    };
}

sub _to_account {
    my ($neutral) = @_;
    no warnings; 
    return {
        id => $neutral->{id},
        accno => $neutral->{account_number},
        description => $neutral->{description},
        category => $rcategory->{$neutral->{category}},
        
    };
}

sub save_account {
    my ($in_account) = @_;
    return unless $in_account;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 0 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $account = LedgerSMB::DBObject::Account->new(base => _to_account($in_account));
    $account->save;

    $LedgerSMB::App_State::DBH->commit;
    return $account->{id};
}

get 'counterparty/:id' => sub { to_json(get_counterparty(param('id'))) };
sub get_counterparty {
    my ($control_code) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 0 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $entity =
         LedgerSMB::Entity::Company->get_by_cc($control_code);
    if (!$entity){
        status('not_found');
        return {};
    }
    $entity ||=  LedgerSMB::Entity::Person->get_by_cc($control_code);
    $entity->{credit_accounts} = [ LedgerSMB::Entity::Credit_Account->list_for_entity(
                     $entity->{id},
                     $entity->{entity_class}
    ) ];
    $entity->{addresses} = [ LedgerSMB::Entity::Location->get_active(
                   {entity_id => $entity->{id},
                    credit_id => undef }
    ) ];

    $entity->{contact_info} = [ LedgerSMB::Entity::Contact->list(
              {entity_id => $entity->{id},
               credit_id => undef, }
    ) ];
    $entity->{bank_accounts} = [ LedgerSMB::Entity::Bank->list($entity->{id}) ];
    $entity->{comments} = [ LedgerSMB::Entity::Note->list($entity->{id},
			            undef) ];
    $LedgerSMB::App_State::DBH->commit;    
    return($entity);

}

sub save_counterparty {
	# todo, but too complex currently.  May need to break off into separate
	# end points
}

sub new_form {
   my ($db, $struct) = @_;
   $struct ||= {};
   my $form = bless { %$struct }, 'Form';
   if ($db){
       $form->{dbh} = $db->connect({ AutoCommit => 0 });
   } else {
       $form->{dbh} = $LedgerSMB::App_State::DBH;
   }
   return $form;
}

sub _inv_order_calc_taxes {
    my ($form) = @_;
    $form->{subtotal} = $form->{invsubtotal};
    my $moneyplaces = $LedgerSMB::Company_Config::settings->{decimal_places};
    for my $i (1 .. $form->{rowcount}){
        my $discount_amount = $form->round_amount( $form->{"sellprice_$i"}
                                      * ($form->{"discount_$i"} / 100),
                                    $moneyplaces);
        my $linetotal = $form->round_amount( $form->{"sellprice_$i"}
                                      - $discount_amount,
                                      $moneyplaces);
        $linetotal = $form->round_amount( $linetotal * $form->{"qty_$i"},
                                          $moneyplaces);
        my @taxaccounts = Tax::init_taxes(
            $form, $form->{"taxaccounts_$i"},
            $form->{'taxaccounts'}
        );
        my $tax;
        my $fxtax;
        my $amount;
        if ( $form->{taxincluded} ) {
            $tax += $amount =
              Tax::calculate_taxes( \@taxaccounts, $form, $linetotal, 1 );

            $form->{"sellprice_$i"} -= $amount / $form->{"qty_$i"};
        }
        else {
            $tax //= LedgerSMB::PGNumber->from_db(0);
            $tax += $amount =
              Tax::calculate_taxes( \@taxaccounts, $form, $linetotal, 0 );
        }
	my $taxes = {};
        for (@taxaccounts) {

            
	    $taxes->{total} ||= 0;
            $taxes->{$_->account}->{rate} = $_->rate;
            $taxes->{$_->account}->{taxes} = 0 if ! $form->{taxes}{$_->account};
            $taxes->{$_->account}->{taxes} += $_->value;
            $taxes->{total} += $_->value;
            if ($_->value){
               $taxes->{$_->account}->{taxbasis} += $linetotal;
            }
        }
	$form->{taxes} = $taxes
    }
}

get 'gns/:id' => sub { to_json(get_part(param('id'))) };
post 'gns/new' => sub { redirect(save_part(from_json(request->body))) };

sub get_part {
        my ($id) = @_;
	my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
	);
	my $form = new_form($db, {id => $id});
	local $LedgerSMB::App_State::DBH = $form->{dbh};;
	local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
	IC->get_part({}, $form);
        status 'not_found' unless $form->{reference};
	return form_to_part($form);
}

sub save_part {
        my ($struct) = @_;
	my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
	);
	my $form = new_form($db, {});
	local $LedgerSMB::App_State::DBH = $form->{dbh};;
	local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
	my $ret = {};
        try {
		IC->save_part({}, part_to_form($struct, $form));
		$ret = $struct;
	} catch {
		status(400);
		warning($_);
		$ret = { error => $_ };
	};
        return $ret;
}

sub form_to_part {
    my ($form) = @_;
    my $type = 'overhead';
    $type = 'service' if $form->{income_accno_id};
    $type = 'part' if $form->{income_accno_id} and $form->{inventory_accno_id};
    $type = 'assembly' if $form->{assembly};
    return {
        id => $form->{id},
        description => $form->{description},
        type => $type, 
        account => { map { $_ => $form->{"${_}_accno_id"} }
	             grep { $form->{"${_}_accno_id"} } qw(income accno expense)
                   },	     
        price => { sell => $form->{sellprice},
                   cost => $form->{lastcost}, 
                   list => $form->{listprice},
                  },
       
    };
       
}

sub part_to_form {
    my ($part) = @_;
    return {
        sellprice => $part->{price}->{sell}, 
        lastcost => $part->{price}->{cost},
        listprice => $part->{price}->{list},
        inventory_accno_id => $part->{account}->{income},
        expense_accno_id => $part->{account}->{expense},
        income_accno_id => $part->{account}->{income},
        description => $part->{description},
        id => $part->{id},
    };
}

sub account_get_by_accno {
    my ($accno) = @_;
       my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
       );
       my $form = new_form($db, {});
       local $LedgerSMB::App_State::DBH = $form->{dbh};;
       local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $acinterface = LedgerSMB::DBObject::Account->new(base => {});
    my %account = map {$_->{accno} => $_ } $acinterface->list();
    return _from_account($account{$accno});
}

my $cclass = {
    phone => 1,
    fax => 9,
    email => 15,
};

sub counterparty_save_contacts {
     my ($eclass, $struct) = @_;
     my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
     );
       my $form = new_form($db, {});
     local $LedgerSMB::App_State::DBH = $form->{dbh};;
     local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
     my $meta_number = $struct->{number};
     my $email =  $struct->{email};
     my $phone =  $struct->{phone};
     my $fax=  $struct->{fax};
     my $eca;
        $eca = LedgerSMB::Entity::Credit_Account->get_by_meta_number($meta_number, $eclass);
     return 0 unless $eca;
     for my $c (keys %$cclass){
         next unless $struct->{$c};
         try {
         my $contact = LedgerSMB::Entity::Contact->new(credit_id => $eca->id, class_id => $cclass->{$c}, contact => $struct->{$c});
         $contact->save;
         };
         $form->{dbh}->commit;
     }
    bill_add_save($eca->id, $struct->{bill_addr}) if $struct->{bill_addr};
    $form->{dbh}->commit;
     return 1;
}

sub bill_add_save {
    my ($eca_id, $address) = @_;
    my $loc = LedgerSMB::Entity::Location->new(
        location_class => 1,
        line_one => $address->{Line1},
        line_two => $address->{Line2},
        line_three => $address->{Line3},
        line_four => $address->{Line4},
        city => $address->{City} || 'NO DATA',
        state => $address->{State} // $address->{CountrySubDivisionCode} // 'NO DATA',
        zipcode => $address->{PostalCode},
        country_id => 232,
        credit_id => $eca_id,
    );
    try {
         $loc->save;
    };
}

post '/customercontacts/new' => sub { to_json({success => counterparty_save_contacts(2, from_json(request->body))}) };

1;


