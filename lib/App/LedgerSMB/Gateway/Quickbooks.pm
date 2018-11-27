
package App::LedgerSMB::Gateway::Quickbooks;
use App::LedgerSMB::Gateway::Internal;
use App::LedgerSMB::Auth qw(authenticate);
use Dancer ':syntax';
use LedgerSMB::Setting;
use Carp;

use strict;
use warnings;

prefix '/lsmbgw/0.1/:company/quickbooks';
our $VERSION = '0.1';

sub je_amount_sign {
    my ($type) = @_;
    warning("Sign for $type requested");
    return -1 if $type eq 'Debit';
    return 1;
}

sub _je_listid_to_accno {
    my ($listid) = @_;
    return LedgerSMB::Setting->get("qbgw-account-$listid");
}

sub _je_lines_to_internal {
    my ($lineref) = @_;
    return [ map {
     my $accno = $_->{AccountRef}->{value} // _je_listid_to_accno($_->{AccountRef}->{ListID}) // $_->{JournalEntryLineDetail}->{AccountRef}->{value};
     {
             account_number => $accno,
             account_description => $_->{JournalEntryLineDetails}->{AccountRef}->{name},
             amount => $_->{Amount} * je_amount_sign($_->{JournalEntryLineDetails}->{PostingType}),
             reference => $_->{source},
           description => $_->{memo},
    }} @$lineref ];
}

sub _je_lines_from_internal {
    my ($lineref) = @_;
    my $i = 0;
    return [ map {
        Id => $i++, 
        Description => $_->{memo},
        Amount => abs($_->{amount}),
	JournalEntryLineDetails => {
            PostingType => ($_->{amount} < 0 ? 'Debit' : 'Credit'),
            AccountRef => { value => $_->{account_number},
                        name  => $_->{account_description}, }
	},
    }, @$lineref];
}

sub unwrap_qbxml{
    my ($struct, $item) = @_;
    for my $i ((qw(QBXML QBXMLMsgsRs), @$item)){
        $struct = $struct->{$i} if $struct->{$i}; 
    }
    return $struct;
}

sub journal_entry_to_internal {
    my ($je) = @_;
    my $line = $je->{Line};
    unless ($line) { # desktop
        $je->{JournalCreditLine} = [$je->{JournalCreditLine}] unless ref $je->{JournalCreditLine} eq 'ARRAY';
        $je->{JournalDebitLine} = [$je->{JournalDebitLine}] unless ref $je->{JournalDebitLine} eq 'ARRAY';
        $line = [ (map {{%$_, JournalEntryLineDetails => { %$_, PostingType => 'Credit'}}} (@{$je->{JournalCreditLine}})),
                  (map {{%$_, JournalEntryLineDetails => { %$_, PostingType => 'Debit'}}} (@{$je->{JournalDebitLine}}))];
    
    }
    my $newje = {
       id => $je->{Id},
       reference => $je->{DocNumber},
       postdate => $je->{TxnDate},
       lineitems => _je_lines_to_internal($line),
        
    };
    use Data::Dumper;
    warning(Dumper($newje));
    return ($newje);
}

sub internal_to_journal_entry {
    my $internal = shift;

    return {
        Adjustment => JSON::false(), # lsmb does not support
        domain => 'QB0', # hard wired
        sparse => JSON::false(), #does not support
        Id => $internal->{id}, #ids correlate
        SyncToken => 1, #does not support
        DocNumber => $internal->{reference},
        TxnDate => $internal->{postdate},
        Line => _je_lines_from_internal($internal->{lineitems}),
        
    };
}

sub get_je {
    my ($id) = @_;
    return internal_to_journal_entry(
        App::LedgerSMB::Gateway::Internal::get_gl($id)
    );
}

sub je_save {
    my ($je) = @_;
    $je = unwrap_qbxml($je, ['JournalEntryQueryRs', 'JournalEntryRet']);
    if (ref $je eq 'ARRAY'){
        je_save($_) for @$je;
        return;
    }
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    return App::LedgerSMB::Gateway::Internal::save_gl( journal_entry_to_internal($je));
}

get '/journal_entry/:id' => sub {to_json(get_je(param('id')))};
post '/journal_entry/new' => sub {warning(request->body); je_save(from_json(request->body)); to_json({success => 1})};

get '/invoice/:id' => sub {to_json(get_invoice(param('id')))};
post '/invoice/new' => sub {redirect(save_invoice(from_json(request->body)))};

sub internal_to_invoice {
    my ($inv) = @_;
    return {
       DocNumber => $inv->{reference},
       TxnDate   => $inv->{postdate},
       Description => $inv->{description},
       TxnTaxDetail => decode_taxes($inv->{taxes}),
       Line => decode_invlines($inv->{lineitems}),
    };
}

sub decode_taxes {
    my ($tax) = $_;
    return {
        TotalTax => $tax->{total},
	TaxLine => [ map { {
          TaxRateRef => { value => $_ },
          TaxPercent => $tax->{$_}->{rate},
          NetAmountTaxable => $tax->{$_}->{taxbasis}	  
	} } grep {$_ =~ /\d/} keys %$tax ]
    };
}

sub encode_taxes {
    my ($tax) = @_;
    return {
    map { $_->{accno} => $_ }
    map { {
        manual => 1,
        accno => $_->{TaxRateRef}->{value},
        rate => $_->{TaxPercent},
        taxbasis => $_->{NetAmountTaxable},
    } } @{$tax->{TaxLine}} };
}

sub encode_invlines {
    my ($lines) = @_;
    return [
    map { {
        description => $_->{Description},
        sellprice => $_->{Amount},
        qty => $_->{SalesItemLineDetail}->{Qty},
        partnumber => $_->{SalesItemLineDetail}->{ItemRef}->{value},
    } }
    @$lines];
}

sub decode_invlines {
    my ($lines) = @_;
    my $linenum = 0;
    return [
    map {
        $linenum += 1;
	{
        Id => $linenum,
	LineNum => $linenum,
	Description => $_->{description},
        Amount => $_->{sellprice},
        DetailType => 'SalesItemLineDetail',
        SalesItemLineDetail => {
           Qty => $_->{qty},
           ItemRef => {
                value => $_->{partnumber},
                name => $_->{description},
                unitprice => $_->{sellprice},
           },
        },
        }
    }
    @$lines ];
}

sub invoice_to_internal {
    my ($bill) = @_;
    return {
       reference => $bill->{DocNumber},
       postdate  => $bill->{TxnDate},
       description => $bill->{Description},
       lineitems => encode_invlines($bill->{Line}),
    };
}
sub get_invoice {
    my ($id) = @_;
    return interal_to_invoice(
        App::LedgerSMB::Gateway::Internal::get_invoice($id)
    );
}

sub save_invoice {
    my ($bill) = @_;
    return App::LedgerSMB::Gateway::Internal::save_invoice(
        invoice_to_internal($bill)
    );
}

get '/bill/:id' => sub {to_json(get_bill(param('id')))};
post '/bill/new' => sub {redirect(save_bill(from_json(request->body)))};

sub encode_bill_lines {
    my ($lines) = @_;
    return [ map { {
        Amount => $_->{amount},
	AccountBasedExpenseLineDetail => { 
              name => $_->{account_desc}, 
              value => $_->{account_number}, 
        },
    } } @$lines ];
}

sub decode_bill_lines {
    my ($lines) = @_;
    return [ map { {
        account_number => $_->{AccountBasedExpenseLineDetail}->{AccountRef}->{value},
        account_desc   => $_->{AccountBasedExpenseLineDetail}->{AccountRef}->{name},
        amount         => $_->{Amount},
    } } @$lines ];

}

sub encode_bill {
    my ($ar) = @_;
    return {
        Id => $ar->{reference},
        DueDate => $ar->{postdate},
        Description => $ar->{description},
        Line => encode_bill_lines($ar->{lineitems}),
        CustomerRef => { value => $ar->{counterparty} }
    };
}

sub decode_bill {
    my ($bill) = $_;
    return {
                    reference => $bill->{Id},
                    postdate  => $bill->{DueDate},
                    description => $bill->{Description},
                    lineitems => decode_bill_lines($bill->{Line}),
                    counterparty => $bill->{CustomerRef}->{value},
            };


}

sub get_bill {
    my ($id) = @_;
    return encode_bill(
        App::LedgerSMB::Gateway::Internal::get_aa($id, 'AP')
    );
}

sub save_bill {
    my ($bill) = @_;
    return App::LedgerSMB::Gateway::Internal::save_aa(
        decode_bill($bill), 'AP'
    );
}

my @acctypes = qw(Asset Liability Equity Income Expense);
my %category_map = (
    Bank =>                  { category => 'Asset',     link => ['AR_paid', 'AP_paid']},
    AccountsReceivable =>    { category => 'Asset',     link => ['AR']},
    AccountsPayable =>       { category => 'Liability', link => ['AP']},
    CreditCard =>            { category => 'Liability', link => ['AP_paid']},
    CostOfGoodsSold =>       { category => 'Expense',   link => ['IC_cogs']},
    NonPosting =>            { category => 'Equity',    link => []},
    'Accounts Receivable' => { category => 'Asset',     link => ['AR']},
    'Accounts Payable' =>    { category => 'Liability', link => ['AP']},
    'Credit Card' =>         { category => 'Liability', link => ['AP_paid']},
    'Cost of Goods Sold' =>  { category => 'Expense',   link => ['IC_cogs']},
);

sub encode_account {
    my ($in) = @_;
    return {
	AccountNumber => $in->{account_number},
        Name => $in->{description},
        FullName => $in->{description},
        AccountType => $in->{category},
    };
}

sub decode_account {
    my ($in) = @_;
    $in->{AccountNumber} //= $in->{ListID};
    my $type = $in->{AccountType};
    my $category;
    for (@acctypes) {
        $category = $_ if $type =~ /$_/i;
    }
    $category ||= $category_map{$type}->{category};
    my $link = $category_map{$type}->{link};
    unless ($category) {
        status '400';
        die 'Unknown category ' . $type;
    }
    LedgerSMB::Setting->set("qbgw-account-$in->{ListID}", $in->{AccountNumber}) if $in->{AccountNumber};
    my ($account) = App::LedgerSMB::Gateway::Internal::account_get_by_accno($in->{AccountNumber})  if $in->{AccountNumber};
    my %extra;
    $extra{id} = $account->{id} if $account;
    return {
	account_number=> $in->{AccountNumber} // $in->{Id},
        description => $in->{FullName},
        category => $category,
        link => $link // [],
        %extra
    };
}

sub get_account {
    my ($id) = @_;
    return encode_account(
        App::LedgerSMB::Gateway::Internal::account_get_by_accno($id)
    );
}

sub save_account {
    my ($account) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    $account = unwrap_qbxml($account, ['AccountQueryRs', 'AccountRet']); 
    if (ref $account eq 'ARRAY'){
        my $ret;
        $ret = save_account($_) for @$account;
        return $ret;
    }
    my $decoded = decode_account($account);
    my $id = App::LedgerSMB::Gateway::Internal::save_account(
        $decoded
    );
    for my $desc (@{$account->{link}}){
        # all values whitelisted so this is safe
        $LedgerSMB::App_State::DBH->do("insert into account_link (account_id, description) values ($id, '$desc')");
    }
}

get '/account/:id' => sub {to_json(get_account(param('id')))};
post '/account/new' => sub {warning(request->body); save_account(from_json(request->body)); to_json({success => 1})};

1;
