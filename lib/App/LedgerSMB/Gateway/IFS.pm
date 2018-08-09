package App::LedgerSMB::Gateway::IFS;

use Dancer ':syntax';

use App::LedgerSMB::Auth qw(authenticate);
use LedgerSMB::App_State;
use LedgerSMB::Sysconfig;
use LedgerSMB::Entity;
use LedgerSMB::Entity::Company;
use LedgerSMB::Entity::Credit_Account;
use LedgerSMB::Entity::Location;
use LedgerSMB::Entity::Contact;
use LedgerSMB::IC;
use LedgerSMB::IS;
use LedgerSMB::IR;
use LedgerSMB::Form;
use Try::Tiny;

prefix '/lsmbgw/0.1/:company/quickbooks';
our $VERSION = '0.1';

sub eca_save {
    my ($entity_class, $cust) = @_;
    my $config = get_accounts_config();
    my $company = LedgerSMB::Entity::Company->get_by_cc($cust->{ListID} // $cust->{value});
    if ($company){
        my ($eca) = LedgerSMB::Entity::Credit_Account->list_for_entity($company->entity_id);
        return $eca->{id} if $eca;
    } else {
        $company = LedgerSMB::Entity::Company->new(
	    control_code => $cust->{ListID} // $cust->{value},
	    legal_name => $cust->{FullName} // $cust->{name},
	    entity_class => $entity_class,
            country_id => 232
        );
        $company->save;
        $company = $company->get_by_cc($company->control_code);
    }
    my $eca = LedgerSMB::Entity::Credit_Account->new(
	    entity_id => $company->entity_id,
	    entity_class => $entity_class,
            ar_ap_account_id => $config->{ar},
    );
    $eca->save;
    return $eca->{id};
}

sub bill_add_save {
    my ($entity_id, $address) = @_;
    my $loc = LedgerSMB::Entity::Location->new(
        line_one => $address->{Line1},
        line_two => $address->{Line2},
        line_three => $address->{Line3},
        line_four => $address->{Line4},
        city => $address->{City},
        state => $address->{State},
        zipcode => $address->{PostalCode},
        country => 232,
    );
    $loc->save;
}

sub bill_email_save {
    my ($entity_id, $email) = @_;
}

sub get_invoice_lineitems {
    my ($struct) = @_;
    my @lines = ();
    my $lineref = $struct->{InvoiceLineRet} // $struct->{ItemLineRet};
    my $innerref;
    $lineref = [$lineref] if ref $lineref eq 'HASH';
    @lines = @$lineref if ref $lineref;
    push @lines, grep {$_->{SalesItemLineDetail}->{"ItemRef"} } @{$struct->{Line}};
    
    $lineref = $struct->{InvoiceLineGroupRet};
    $lineref = [$lineref] if ref $lineref eq 'HASH';
    $lineref = [] unless ref $lineref;

    for (@$lineref){
        $innerref = $_->{InvoiceLineRet};
        $innerref = [$lineref] if ref $innerref eq 'HASH';
        $innerref = [] unless ref $innerref ;
        push @lines, @$innerref;
        
    }
    @lines = map {ref $_ eq 'ARRAY' ? @$_ : $_ } @lines;
    return @lines;
}

sub get_accounts_config{
    my $setname = 'GW-qbaccounts';
    my $config_json = LedgerSMB::Setting->get($setname);
    return from_json($config_json) if $config_json;
    # create accounts
    # 1000-lsmbpay, our internal payment
    my $acc1100 = LedgerSMB::DBObject::Account->new(base => {
        accno => '1100-lsmbar',
        category => 'A',
	description => 'internal lsmb gateway ar acct',
	link => ['AR']
    });
    my $acc2100 = LedgerSMB::DBObject::Account->new(base => {
        accno => '2100-lsmbap',
        category => 'L',
        description => 'internal lsmb gateway ar acct',
        link => ['AP']
    });
    $acc2100->save;

    $acc1100->save;
    my $acc1000 = LedgerSMB::DBObject::Account->new(base => {
        accno => '1000-lsmbpay',
        category => 'A',
	description => 'internal lsmb gateway payment acct',
	link => ['AR_paid', 'AP_paid']
    });
    $acc1000->save;
    # 1500-lsmbinv, our internal inventory assets
    my $acc1500 = LedgerSMB::DBObject::Account->new(base => {
        accno => '1500-lsmbpay',
        category => 'A',
	description => 'internal lsmb gateway inventory acct',
	link => ['IC']
        
    });
    $acc1500->save;
    # 4500-lsmbinv, our internal sales revenue
    my $acc4500 = LedgerSMB::DBObject::Account->new(base => {
        accno => '4500-lsmbinv',
        category => 'I',
	description => 'internal lsmb revenue acct',
	link => ['AR_amount', 'IC_sale']
    });
    $acc4500->save;
    # 5500-lsmbinv, our internal cogs
    my $acc5500 = LedgerSMB::DBObject::Account->new(base => {
        accno => '5500-lsmbinv',
        category => 'E',
	description => 'internal lsmb gateway cogs acct',
	link => ['AP_amount', 'IC_cogs']
    });
    $acc5500->save;
    # save map
    my $map = {
        ar => $acc1100->{id},
       pay => $acc1000->{id}, 
       inventory => $acc1500->{id},
       sales => $acc4500->{id},
       cogs => $acc5500->{id},
    };
    my $setting = LedgerSMB::Setting->set($setname, to_json($map));
    return $map;
}

sub get_part{
    my ($line) = @_;
    my $listid;
    $listid = ($line->{ItemRef}->{ListID} // $line->{SalesItemLineDetail}->{ItemRef}->{value}) if exists $line->{ItemRef};
    $listid //= $line->{ClassRef}->{ListID};
    my $sql = "SELECT * FROM parts WHERE partnumber = ?";
    my $sth = LedgerSMB::App_State::DBH->prepare($sql);
    $sth->execute($listid);
    return $sth->fetchrow_hashref('NAME_lc');
}

#{"Id": "3", "Line": [{"Id": "1", "Amount": 290, "LineNum": 1, "LinkedTxn": [], "DetailType": "SalesItemLineDetail", "CustomField": [], "Description": "test", "SalesItemLineDetail": {"Qty": 58, "ItemRef": {"name": "Sales", "type": "", "value": "1"}, "ClassRef": null, "UnitPrice": 5, "MarkupInfo": null, "TaxCodeRef": {"name": "", "type": "", "value": "NON"}, "ServiceDate": "", "PriceLevelRef": null, "TaxInclusiveAmt": 0}}, {"Id": null, "Amount": 290, "LineNum": 0, "LinkedTxn": [], "DetailType": "SubTotalLineDetail", "CustomField": [], "Description": null, "SubTotalLineDetail": {}, "SubtotalLineDetail": null}], "domain": "QBO", "sparse": false, "Balance": 290, "Deposit": 0, "DueDate": "2018-09-05", "TxnDate": "2018-08-06", "BillAddr": {"Id": "5", "Lat": "", "City": "", "Long": "", "Note": "", "Line1": "Mr Harry J Potter", "Line2": "Hogwarts", "Line3": "test", "Line4": "test, test  test test", "Line5": "", "Country": "", "PostalCode": "", "CountrySubDivisionCode": ""}, "MetaData": {"CreateTime": "2018-08-06T06:53:46-07:00", "LastUpdatedTime": "2018-08-06T06:53:46-07:00"}, "ShipAddr": {"Id": "2", "Lat": "", "City": "test", "Long": "", "Note": "", "Line1": "test", "Line2": "", "Line3": "", "Line4": "", "Line5": "", "Country": "test", "PostalCode": "test", "CountrySubDivisionCode": "test"}, "ShipDate": "", "TotalAmt": 290, "BillEmail": {"Address": "test1@devifg.com"}, "DocNumber": "1003", "LinkedTxn": [], "SyncToken": "0", "CurrencyRef": {"name": "United States Dollar", "type": "", "value": "USD"}, "CustomField": [], "CustomerRef": {"name": "Mr Harry Potter", "type": "", "value": "1"}, "EmailStatus": "NotSet", "PrintStatus": "NotSet", "PrivateNote": "", "TrackingNum": "", "customer_id": "3", "CustomerMemo": null, "DeliveryInfo": null, "ExchangeRate": 1, "SalesTermRef": {"name": "", "type": "", "value": "3"}, "TxnTaxDetail": null, "DepartmentRef": null, "EInvoiceStatus": null, "AllowIPNPayment": false, "AllowOnlinePayment": false, "GlobalTaxCalculation": "TaxExcluded", "AllowOnlineACHPayment": false, "ApplyTaxAfterDiscount": false, "AllowOnlineCreditCardPayment": false}
sub parts_save {
    my ($line) = @_;
    unless (ref $line eq 'HASH'){
        warning(to_json($line)) if ref $line;
        warning("bad line: $line");
        return;
    }
    warning( $line->{Desc} // $line->{Description});
    my $listid;
    my $part = get_part($line);
    warning("$part " . to_json($line));
    $line->{Quantity} //= 1;
    if ($part){
        return {
           id => $part->{id},
           description => $line->{Desc} // $line->{Description},
           sellprice => $line->{Rate} // $line->{UnitPrice},
	   qty => $line->{Quantity} // $line->{"SalesItemLineDetail"}->{Qty},
	};
    } else {
        my $config = get_accounts_config();
        my $part;
        if (!exists $line->{ItemRef}){
            $part = {
               partnumber => $line->{ClassRef}->{ListID},
               description => $line->{Desc}, 
               IC_income => '4500-lsmbinv',
               IC_expense => '5500-lsmbinv',
               sellprice => 1,
               dbh => $LedgerSMB::App_State::DBH,
            };
        } else {
            $part = {
               partnumber => $line->{ItemRef}->{ListID} // $line->{ItemRef}->{value},
               description => $line->{Desc} // $line->{Description}, 
               IC_income => '4500-lsmbinv',
               IC_expense => '5500-lsmbinv',
	       IC_inventory => '1500-lsmbinv',
               sellprice => $line->{Rate} // $line->{UnitPrice},
               dbh => $LedgerSMB::App_State::DBH,
            };
        }
        bless $part, 'Form';
        IC->save({}, $part);
        $line->{Rate} //= $line->{Amount}; 
        $line->{Quantity} //= 1;
        $line->{Rate} *= -1 if $line->{RatePercent};
        return {
           id => $part->{id},
           description => $line->{Desc},
           sellprice => $line->{Rate},
	   qty => $line->{Quantity},
	};
    }
}

sub bill_save {
    my ($struct) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    $struct = App::LedgerSMB::Gateway::Quickbooks::unwrap_qbxml($struct, ['BillQueryRs', 'BillRet']);
    if (ref $struct eq 'ARRAY') {
        bill_save($_) for @$struct;
        return 'success';
    }
    $struct->{vendor_id} = eca_save(1, $struct->{"VendorRef"});
    return save_vendorinvoice(bill_to_vi($struct));
}

sub bill_to_vi {
    my ($struct) = @_;
    my $curr = 'USD';
    my $initial = {
        vc => 'vendor',
        invnumber => $struct->{TxnNumber} // $struct->{DocNumber},
        exchangerate => 1,
	arap => 'ap',
	ARAP => 'AP',
        vendor_id => $struct->{vendor_id},
        AP => '2100-lsmbap',
        transdate => $struct->{TxnDate},
        duedate => $struct->{DueDate},
        currency => $curr,
        intnotes => to_json($struct),
    };
    my $rowcount = 1;
    my @lines = get_invoice_lineitems($struct);
    for (@lines){
        my $linestruct = parts_save($_);
        $linestruct->{sellprice} = $_->{Amount} if $_->{Amount};
        $initial->{"${_}_$rowcount"} = $linestruct->{$_} for keys %$linestruct;
	++$rowcount;
    }
    $initial->{rowcount} = $rowcount;
    $struct->{linkedTxn} = [$struct->{linkedTxn}] if ref $struct->{linkedTxn} eq 'HASH';
    my $paidrows = 0;
    try {
    for (grep  { $_->{TxnType} eq 'ReceivePayment'} @{$struct->{LinkedTxn}}){
       my $amount = $_->{Amount} * -1;
       my $linestruct = {
         AR_Paid => '1100-lsmbpay',
         paid => $amount,
         datepaid => $_->{TxnDate},
         source => $_->{RefNumber},
       };
        $initial->{"${_}_$paidrows"} = $linestruct->{$_} for keys %$linestruct;
	++$paidrows;
        
    }
    };
    $initial->{paidaccounts} = $paidrows;
    return $initial;
}

sub invoice_save {
    my ($struct) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    $struct = App::LedgerSMB::Gateway::Quickbooks::unwrap_qbxml($struct, ['InvoiceQueryRs', 'InvoiceRet']);
    if (ref $struct eq 'ARRAY') {
        invoice_save($_) for @$struct;
        return 'success';
    }
    $struct->{customer_id} = eca_save(2, $struct->{CustomerRef});
    return save_salesinvoice(invoice_to_si($struct));
}

sub save_vendorinvoice {
    my ($struct) = @_;
    my $form = App::LedgerSMB::Gateway::Internal::new_form(undef, $struct);
    try {
        IR->post_invoice({}, $form);
    } catch {
        warning($_);
    };
    return 'success';
}

sub save_salesinvoice {
    my ($struct) = @_;
    my $form = App::LedgerSMB::Gateway::Internal::new_form(undef, $struct);
    try {
        IS->post_invoice({}, $form);
    } catch {
        warning($_);
    };
    return 'success';
}

sub invoice_to_si {
    my ($struct) = @_;
    my $curr = 'USD';
    my $initial = {
        vc => 'customer',
        invnumber => $struct->{TxnNumber} // $struct->{DocNumber},
        transdate => $struct->{TxnDate},
        currency => 'USD',
        exchangerate => 1,
	arap => 'ar',
	ARAP => 'AR',
	customer_id => $struct->{customer_id},
        AR => '1100-lsmbar',
        duedate => $struct->{DueDate},
        currency => $curr,
        intnotes => to_json($struct),
    };
    my $rowcount = 1;
    $struct->{InvoiceLineRet} = [$struct->{InvoiceLineRet}] if ref $struct->{InvoiceLineRet} eq 'HASH';
    my @lines = get_invoice_lineitems($struct);
    for (@lines){
        my $linestruct = parts_save($_);
        $initial->{"${_}_$rowcount"} = $linestruct->{$_} for keys %$linestruct;
	++$rowcount;
    }
    my $paidrows = 1;
    $struct->{linkedTxn} = [$struct->{linkedTxn}] if ref $struct->{linkedTxn} eq 'HASH';
    try {
    for (grep  { $_->{TxnType} eq 'ReceivePayment'} @{$struct->{linkedTxn}}){
       my $linestruct = {
         AR_Paid => '1100-lsmbpay',
         paid => $_->{Amount} * -1,
         datepaid => $_->{TxnDate},
         source => $_->{RefNumber},
       };
        $initial->{"${_}_$paidrows"} = $linestruct->{$_} for keys %$linestruct;
	++$paidrows;
        
    }
    };
    $initial->{rowcount} = $rowcount;
    $initial->{paidaccounts} = $paidrows;
    return $initial;
}

post '/purchase/new' => sub {warning(request->body); bill_save(from_json(request->body)); to_json({success => 1})};

post '/sales/new' => sub {warning(request->body); invoice_save(from_json(request->body)); to_json({success => 1})};
