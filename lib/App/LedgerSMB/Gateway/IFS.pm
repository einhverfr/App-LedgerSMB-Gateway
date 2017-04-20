package App::LedgerSMB::Gateway::IFS;

use Dancer ':syntax';

use App::LedgerSMB::Auth qw(authenticate);
use LedgerSMB::Entity;
use LedgerSMB::Entity::Company;
use LedgerSMB::Entity::Credit_Account;
use LedgerSMB::IC;
use LedgerSMB::IS;
use LedgerSMB::IR;

prefix '/lsmbgw/0.1/:company/quickbooks';
our $VERSION = '0.1';

sub eca_save {
    my ($entity_class, $cust) = @_;
    my $company = LedgerSMB::Entity::Company->new(
	    control_code => $cust->{ListID},
	    legal_name => $cust->{FullName},
	    entity_class => $entity_class,
    );
    $company->save;
    my $eca = LedgerSMB::Entity::Credit_Account->new(
	    entity_id => $company->{entity_id},
	    entity_class => $entity_class,
    );
    $eca->save;
    return $eca->{id};
}

sub parts_save {
}

sub bill_save {
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my ($struct) = @_;
    $struct = App::LedgerSMB::Quickbooks::unwrap_qbxml(['BillQueryRs', 'BillQueryRet']);
    if (ref $struct eq 'ARRAY') {
        bill_save($_) for @$struct;
    }
    $struct->{vendor_id} = eca_save(1, $struct->{VendorRef});
    $_->{part_id} = parts_save($_) for @{$struct->{ItemLineRet}};
    return App::LedgerSMB::Gateway::Internal::save_salesinvoice(bill_to_vi($struct));
}

sub bill_to_vi {
}

sub invoice_save {
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my ($struct) = @_;
    $struct = App::LedgerSMB::Quickbooks::unwrap_qbxml(['InvoiceQueryRs', 'InvoiceRet']);
    if (ref $struct eq 'ARRAY') {
        invoice_save($_) for @$struct;
    }
    $struct->{customer_id} = eca_save(2, $struct->{CustomerRef});
    $_->{part_id} = parts_save($_) for @{$struct->{ItemLineRet}};
    return App::LedgerSMB::Gateway::Internal::save_vendorinvoice(invoice_to_si($struct));
}

sub invoice_to_si {
}

post '/sales/new' => sub {warning(request->body); bill_save(from_json(request->body)); to_json({success => 1})};

post '/purchase/new' => sub {warning(request->body); invoice_save(from_json(request->body)); to_json({success => 1})};
