
package App::LedgerSMB::Gateway::Quickbooks;
use App::LedgerSMB::Gateway::Internal;
use Dancer ':syntax';

prefix '/lsmbgw/0.1/:company/quickbooks';
our $VERSION = '0.1';

sub journalentry_route {
    # will be needed when we support ar/ap transactions here
}

sub je_amount_sign {
    my ($type) = @_;
    return -1 if $type eq 'Debit';
    return 1;
}

sub _je_lines_to_internal {
    my ($lineref) = @_;
    return [ map {
             account_number => $_->{AccountRef}->{value},
             account_description => $_->{AccountRef}->{name},
             amount => $_->{Amount} * je_amount_sign($_->{JournalEntryLineDetail}->{PostingType}),
             reference => $_->{source},
           description => $_->{memo},
    }, @$lineref ];
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

sub journalentry_to_internal {
    my ($je) = @_;
    return {
       id => $je->{Id},
       reference => $je->{DocNumber},
       postdate => $je->{TxnDate},
       lineitems => _je_lines_to_internal($je->{Line}),
        
    };
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
    return App::LedgerSMB::Gateway::Internal::save_gl(
        journal_entry_to_internal($je)
    );
}

get '/journal_entry/:id' => sub {to_json(get_je(param('id')))};
post '/journal_entry/new' => sub {redirect(je_save(from_json(request->body)))};

get '/invoice/:id' => sub {to_json(get_bill(param('id')))};
post '/invoice/:id' => sub {redirect(save_bill(from_json(request->body)))};

sub internal_to_invoice {
    my ($inv) = @_;
    return {
       
       
       
       
    };
}

sub invoice_to_internal {
    my ($bill) = @_;
    return {
       
       
       
       
    };
}
sub get_bill {
    my ($id) = @_;
    return interal_to_bill(
        App::LedgerSMB::Gateway::Internal::get_invoice($id)
    );
}

sub save_bill {
    my ($bill) = @_;
    return App::LedgerSMB::Gateway::Internal::save_invoice(
        bill_to_internal($bill)
    );
}

1;

