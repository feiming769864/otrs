# --
# Kernel/System/Service.pm - all service function
# Copyright (C) 2001-2012 OTRS AG, http://otrs.org/
# --
# $Id: Service.pm,v 1.51 2012-06-04 21:28:03 ub Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::Service;

use strict;
use warnings;

use Kernel::System::CheckItem;
use Kernel::System::Valid;
use Kernel::System::Cache;
use Kernel::System::VariableCheck qw(:all);

use vars qw(@ISA $VERSION);
$VERSION = qw($Revision: 1.51 $) [1];

=head1 NAME

Kernel::System::Service - service lib

=head1 SYNOPSIS

All service functions.

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create an object

    use Kernel::Config;
    use Kernel::System::Encode;
    use Kernel::System::Log;
    use Kernel::System::Main;
    use Kernel::System::DB;
    use Kernel::System::Service;

    my $ConfigObject = Kernel::Config->new();
    my $EncodeObject = Kernel::System::Encode->new(
        ConfigObject => $ConfigObject,
    );
    my $LogObject = Kernel::System::Log->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
    );
    my $MainObject = Kernel::System::Main->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
    );
    my $DBObject = Kernel::System::DB->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
        MainObject   => $MainObject,
    );
    my $ServiceObject = Kernel::System::Service->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
        DBObject     => $DBObject,
        MainObject   => $MainObject,
    );

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # check needed objects
    for my $Object (qw(DBObject ConfigObject LogObject EncodeObject MainObject)) {
        $Self->{$Object} = $Param{$Object} || die "Got no $Object!";
    }
    $Self->{CheckItemObject} = Kernel::System::CheckItem->new( %{$Self} );
    $Self->{ValidObject}     = Kernel::System::Valid->new( %{$Self} );
    $Self->{CacheObject}     = Kernel::System::Cache->new( %{$Self} );

    # load generator preferences module
    my $GeneratorModule = $Self->{ConfigObject}->Get('Service::PreferencesModule')
        || 'Kernel::System::Service::PreferencesDB';
    if ( $Self->{MainObject}->Require($GeneratorModule) ) {
        $Self->{PreferencesObject} = $GeneratorModule->new(%Param);
    }

    # set the cache TTL (in seconds)
    $Self->{CacheTTL} = 3600;

    return $Self;
}

=item ServiceList()

return a hash list of services

    my %ServiceList = $ServiceObject->ServiceList(
        Valid  => 0,   # (optional) default 1 (0|1)
        UserID => 1,
    );

=cut

sub ServiceList {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{UserID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need UserID!',
        );
        return;
    }

    # check valid param
    if ( !defined $Param{Valid} ) {
        $Param{Valid} = 1;
    }

    # ask database
    $Self->{DBObject}->Prepare(
        SQL => 'SELECT id, name, valid_id FROM service',
    );

    # fetch the result
    my %ServiceList;
    my %ServiceValidList;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        $ServiceList{ $Row[0] }      = $Row[1];
        $ServiceValidList{ $Row[0] } = $Row[2];
    }

    return %ServiceList if !$Param{Valid};

    # get valid ids
    my @ValidIDs = $Self->{ValidObject}->ValidIDsGet();

    # duplicate service list
    my %ServiceListTmp = %ServiceList;

    # add suffix for correct sorting
    for my $ServiceID ( keys %ServiceListTmp ) {
        $ServiceListTmp{$ServiceID} .= '::';
    }

    my %ServiceInvalidList;
    SERVICEID:
    for my $ServiceID ( sort { $ServiceListTmp{$a} cmp $ServiceListTmp{$b} } keys %ServiceListTmp )
    {

        my $Valid = scalar grep { $_ eq $ServiceValidList{$ServiceID} } @ValidIDs;

        next SERVICEID if $Valid;

        $ServiceInvalidList{ $ServiceList{$ServiceID} } = 1;
        delete $ServiceList{$ServiceID};
    }

    # delete invalid services and childs
    for my $ServiceID ( keys %ServiceList ) {

        INVALIDNAME:
        for my $InvalidName ( keys %ServiceInvalidList ) {

            if ( $ServiceList{$ServiceID} =~ m{ \A \Q$InvalidName\E :: }xms ) {
                delete $ServiceList{$ServiceID};
                last INVALIDNAME;
            }
        }
    }

    return %ServiceList;
}

=item ServiceListGet()

return a list of services with the complete list of attributes for each service

    my $ServiceList = $ServiceObject->ServiceListGet(
        Valid  => 0,   # (optional) default 1 (0|1)
        UserID => 1,
    );

    returns

    $ServiceList = [
        {
            ServiceID  => 1,
            ParentID   => 0,
            Name       => 'MyService',
            NameShort  => 'MyService',
            ValidID    => 1,
            Comment    => 'Some Comment'
            CreateTime => '2011-02-08 15:08:00',
            ChangeTime => '2011-06-11 17:22:00',
            CreateBy   => 1,
            ChangeBy   => 1,
        },
        {
            ServiceID  => 2,
            ParentID   => 1,
            Name       => 'MyService::MySubService',
            NameShort  => 'MySubService',
            ValidID    => 1,
            Comment    => 'Some Comment'
            CreateTime => '2011-02-08 15:08:00',
            ChangeTime => '2011-06-11 17:22:00',
            CreateBy   => 1,
            ChangeBy   => 1,
        },
        # ...
    ];

=cut

sub ServiceListGet {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{UserID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need UserID!',
        );
        return;
    }

    # check valid param
    if ( !defined $Param{Valid} ) {
        $Param{Valid} = 1;
    }

    # check cached resutls
    my $CacheKey = 'Cache::ServiceListGet::Valid::' . $Param{Valid};
    my $Cache    = $Self->{CacheObject}->Get(
        Type => 'Service',
        Key  => $CacheKey,
    );

    # return cache if any
    if ( defined $Cache ) {
        return $Cache;
    }

    # create SQL query
    my $SQL = 'SELECT id, name, valid_id, comments, create_time, create_by, change_time, change_by '
        . 'FROM service';

    if ( $Param{Valid} ) {
        $SQL .= ' WHERE valid_id IN (' . join ', ', $Self->{ValidObject}->ValidIDsGet() . ')';
    }

    $SQL .= ' ORDER BY name';

    # ask database
    $Self->{DBObject}->Prepare(
        SQL => $SQL,
    );

    # fetch the result
    my @ServiceList;
    my %ServiceName2ID;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        my %ServiceData;
        $ServiceData{ServiceID}  = $Row[0];
        $ServiceData{Name}       = $Row[1];
        $ServiceData{ValidID}    = $Row[2];
        $ServiceData{Comment}    = $Row[3] || '';
        $ServiceData{CreateTime} = $Row[4];
        $ServiceData{CreateBy}   = $Row[5];
        $ServiceData{ChangeTime} = $Row[6];
        $ServiceData{ChangeBy}   = $Row[7];

        # add service data to service list
        push @ServiceList, \%ServiceData;

        # build service id lookup hash
        $ServiceName2ID{ $ServiceData{Name} } = $ServiceData{ServiceID};
    }

    for my $ServiceData (@ServiceList) {

        # create short name and parentid
        $ServiceData->{NameShort} = $ServiceData->{Name};
        if ( $ServiceData->{Name} =~ m{ \A (.*) :: (.+?) \z }xms ) {
            my $ParentName = $1;
            $ServiceData->{NameShort} = $2;
            $ServiceData->{ParentID}  = $ServiceName2ID{$ParentName};
        }

        # get service preferences
        my %Preferences = $Self->ServicePreferencesGet(
            ServiceID => $ServiceData->{ServiceID},
        );

        # merge hash
        if (%Preferences) {
            %{$ServiceData} = ( %{$ServiceData}, %Preferences );
        }
    }

    if (@ServiceList) {

        # set cache
        $Self->{CacheObject}->Set(
            Type  => 'Service',
            Key   => $CacheKey,
            Value => \@ServiceList,
            TTL   => $Self->{CacheTTL},
        );
    }

    return \@ServiceList;
}

=item ServiceGet()

return a service as hash

Return
    $ServiceData{ServiceID}
    $ServiceData{ParentID}
    $ServiceData{Name}
    $ServiceData{NameShort}
    $ServiceData{ValidID}
    $ServiceData{Comment}
    $ServiceData{CreateTime}
    $ServiceData{CreateBy}
    $ServiceData{ChangeTime}
    $ServiceData{ChangeBy}

    my %ServiceData = $ServiceObject->ServiceGet(
        ServiceID => 123,
        UserID    => 1,
    );

    my %ServiceData = $ServiceObject->ServiceGet(
        Name    => 'Service::SubService',
        UserID  => 1,
    );

=cut

sub ServiceGet {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{UserID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Need UserID!",
        );
        return;
    }

    # either ServiceID or Name must be passed
    if ( !$Param{ServiceID} && !$Param{Name} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need ServiceID or Name!',
        );
        return;
    }

    # check that not both ServiceID and Name are given
    if ( $Param{ServiceID} && $Param{Name} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need either ServiceID OR Name - not both!',
        );
        return;
    }

    # lookup the ServiceID
    if ( $Param{Name} ) {
        $Param{ServiceID} = $Self->ServiceLookup(
            Name => $Param{Name},
        );
    }

    # get service from db
    $Self->{DBObject}->Prepare(
        SQL =>
            'SELECT id, name, valid_id, comments, create_time, create_by, change_time, change_by '
            . 'FROM service WHERE id = ?',
        Bind  => [ \$Param{ServiceID} ],
        Limit => 1,
    );

    # fetch the result
    my %ServiceData;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        $ServiceData{ServiceID}  = $Row[0];
        $ServiceData{Name}       = $Row[1];
        $ServiceData{ValidID}    = $Row[2];
        $ServiceData{Comment}    = $Row[3] || '';
        $ServiceData{CreateTime} = $Row[4];
        $ServiceData{CreateBy}   = $Row[5];
        $ServiceData{ChangeTime} = $Row[6];
        $ServiceData{ChangeBy}   = $Row[7];
    }

    # check service
    if ( !$ServiceData{ServiceID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "No such ServiceID ($Param{ServiceID})!",
        );
        return;
    }

    # create short name and parentid
    $ServiceData{NameShort} = $ServiceData{Name};
    if ( $ServiceData{Name} =~ m{ \A (.*) :: (.+?) \z }xms ) {
        $ServiceData{NameShort} = $2;

        # lookup parent
        my $ServiceID = $Self->ServiceLookup(
            Name => $1,
        );
        $ServiceData{ParentID} = $ServiceID;
    }

    # get service preferences
    my %Preferences = $Self->ServicePreferencesGet(
        ServiceID => $Param{ServiceID},
    );

    # merge hash
    if (%Preferences) {
        %ServiceData = ( %ServiceData, %Preferences );
    }

    return %ServiceData;
}

=item ServiceLookup()

return a service name and id

    my $ServiceName = $ServiceObject->ServiceLookup(
        ServiceID => 123,
    );

    or

    my $ServiceID = $ServiceObject->ServiceLookup(
        Name => 'Service::SubService',
    );

=cut

sub ServiceLookup {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{ServiceID} && !$Param{Name} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need ServiceID or Name!',
        );
        return;
    }

    if ( $Param{ServiceID} ) {

        # check cache
        my $CacheKey = 'Cache::ServiceLookup::ID::' . $Param{ServiceID};
        if ( defined $Self->{$CacheKey} ) {
            return $Self->{$CacheKey};
        }

        # lookup
        $Self->{DBObject}->Prepare(
            SQL   => 'SELECT name FROM service WHERE id = ?',
            Bind  => [ \$Param{ServiceID} ],
            Limit => 1,
        );
        while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
            $Self->{$CacheKey} = $Row[0];
        }

        return $Self->{$CacheKey};
    }
    else {

        # check cache
        my $CacheKey = 'Cache::ServiceLookup::Name::' . $Param{Name};
        if ( defined $Self->{$CacheKey} ) {
            return $Self->{$CacheKey};
        }

        # lookup
        $Self->{DBObject}->Prepare(
            SQL   => 'SELECT id FROM service WHERE name = ?',
            Bind  => [ \$Param{Name} ],
            Limit => 1,
        );
        while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
            $Self->{$CacheKey} = $Row[0];
        }

        return $Self->{$CacheKey};
    }
}

=item ServiceAdd()

add a service

    my $ServiceID = $ServiceObject->ServiceAdd(
        Name     => 'Service Name',
        ParentID => 1,           # (optional)
        ValidID  => 1,
        Comment  => 'Comment',    # (optional)
        UserID   => 1,
    );

=cut

sub ServiceAdd {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Argument (qw(Name ValidID UserID)) {
        if ( !$Param{$Argument} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Need $Argument!",
            );
            return;
        }
    }

    # set comment
    $Param{Comment} ||= '';

    # cleanup given params
    for my $Argument (qw(Name Comment)) {
        $Self->{CheckItemObject}->StringClean(
            StringRef         => \$Param{$Argument},
            RemoveAllNewlines => 1,
            RemoveAllTabs     => 1,
        );
    }

    # check service name
    if ( $Param{Name} =~ m{ :: }xms ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Can't add service! Invalid Service name '$Param{Name}'!",
        );
        return;
    }

    # create full name
    $Param{FullName} = $Param{Name};

    # get parent name
    if ( $Param{ParentID} ) {
        my $ParentName = $Self->ServiceLookup( ServiceID => $Param{ParentID}, );
        if ($ParentName) {
            $Param{FullName} = $ParentName . '::' . $Param{Name};
        }
    }

    # find existing service
    $Self->{DBObject}->Prepare(
        SQL   => 'SELECT id FROM service WHERE name = ?',
        Bind  => [ \$Param{FullName} ],
        Limit => 1,
    );
    my $Exists;
    while ( $Self->{DBObject}->FetchrowArray() ) {
        $Exists = 1;
    }

    # add service to database
    if ($Exists) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Can\'t add service! Service with same name and parent already exists.'
        );
        return;
    }

    return if !$Self->{DBObject}->Do(
        SQL => 'INSERT INTO service '
            . '(name, valid_id, comments, create_time, create_by, change_time, change_by) '
            . 'VALUES (?, ?, ?, current_timestamp, ?, current_timestamp, ?)',
        Bind => [
            \$Param{FullName}, \$Param{ValidID}, \$Param{Comment},
            \$Param{UserID}, \$Param{UserID},
        ],
    );

    # get service id
    $Self->{DBObject}->Prepare(
        SQL   => 'SELECT id FROM service WHERE name = ?',
        Bind  => [ \$Param{FullName} ],
        Limit => 1,
    );
    my $ServiceID;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        $ServiceID = $Row[0];
    }

    # reset cache
    delete $Self->{ 'Cache::ServiceLookup::ID::' . $ServiceID };
    delete $Self->{ 'Cache::ServiceLookup::Name::' . $Param{FullName} };

    $Self->{CacheObject}->CleanUp(
        Type => 'Service',
    );

    return $ServiceID;
}

=item ServiceUpdate()

update a existing service

    my $True = $ServiceObject->ServiceUpdate(
        ServiceID => 123,
        ParentID  => 1,           # (optional)
        Name      => 'Service Name',
        ValidID   => 1,
        Comment   => 'Comment',    # (optional)
        UserID    => 1,
    );

=cut

sub ServiceUpdate {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Argument (qw(ServiceID Name ValidID UserID)) {
        if ( !$Param{$Argument} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Need $Argument!",
            );
            return;
        }
    }

    # set default comment
    $Param{Comment} ||= '';

    # cleanup given params
    for my $Argument (qw(Name Comment)) {
        $Self->{CheckItemObject}->StringClean(
            StringRef         => \$Param{$Argument},
            RemoveAllNewlines => 1,
            RemoveAllTabs     => 1,
        );
    }

    # check service name
    if ( $Param{Name} =~ m{ :: }xms ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Can't update service! Invalid Service name '$Param{Name}'!",
        );
        return;
    }

    # get old name of service
    my $OldServiceName = $Self->ServiceLookup( ServiceID => $Param{ServiceID}, );

    if ( !$OldServiceName ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Can't update service! Service '$Param{ServiceID}' does not exist.",
        );
        return;
    }

    # reset cache
    delete $Self->{ 'Cache::ServiceLookup::ID::' . $Param{ServiceID} };
    delete $Self->{ 'Cache::ServiceLookup::Name::' . $OldServiceName };

    $Self->{CacheObject}->CleanUp(
        Type => 'Service',
    );

    # create full name
    $Param{FullName} = $Param{Name};

    # get parent name
    if ( $Param{ParentID} ) {

        # lookup service
        my $ParentName = $Self->ServiceLookup(
            ServiceID => $Param{ParentID},
        );

        if ($ParentName) {
            $Param{FullName} = $ParentName . '::' . $Param{Name};
        }

        # check, if selected parent was a child of this service
        if ( $Param{FullName} =~ m{ \A ( \Q$OldServiceName\E ) :: }xms ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => 'Can\'t update service! Invalid parent was selected.'
            );
            return;
        }
    }

    # find exists service
    $Self->{DBObject}->Prepare(
        SQL   => 'SELECT id FROM service WHERE name = ?',
        Bind  => [ \$Param{FullName} ],
        Limit => 1,
    );
    my $Exists;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        if ( $Param{ServiceID} ne $Row[0] ) {
            $Exists = 1;
        }
    }

    # update service
    if ($Exists) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Can\'t update service! Service with same name and parent already exists.'
        );
        return;

    }

    # update service
    return if !$Self->{DBObject}->Do(
        SQL => 'UPDATE service SET name = ?, valid_id = ?, comments = ?, '
            . ' change_time = current_timestamp, change_by = ? WHERE id = ?',
        Bind => [
            \$Param{FullName}, \$Param{ValidID}, \$Param{Comment},
            \$Param{UserID}, \$Param{ServiceID},
        ],
    );

    # find all childs
    $Self->{DBObject}->Prepare(
        SQL => "SELECT id, name FROM service WHERE name LIKE '"
            . $Self->{DBObject}->Quote( $OldServiceName, 'Like' )
            . "::%'",
    );
    my @Childs;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        my %Child;
        $Child{ServiceID} = $Row[0];
        $Child{Name}      = $Row[1];
        push @Childs, \%Child;
    }

    # update childs
    for my $Child (@Childs) {
        $Child->{Name} =~ s{ \A ( \Q$OldServiceName\E ) :: }{$Param{FullName}::}xms;
        $Self->{DBObject}->Do(
            SQL => 'UPDATE service SET name = ? WHERE id = ?',
            Bind => [ \$Child->{Name}, \$Child->{ServiceID} ],
        );
    }
    return 1;
}

=item ServiceSearch()

return service ids as an array

    my @ServiceList = $ServiceObject->ServiceSearch(
        Name   => 'Service Name', # (optional)
        Limit  => 122,            # (optional) default 1000
        UserID => 1,
    );

=cut

sub ServiceSearch {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{UserID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need UserID!',
        );
        return;
    }

    # set default limit
    $Param{Limit} ||= 1000;

    # create sql query
    my $SQL
        = "SELECT id FROM service WHERE valid_id IN ( ${\(join ', ', $Self->{ValidObject}->ValidIDsGet())} )";

    if ( $Param{Name} ) {

        # quote
        $Param{Name} = $Self->{DBObject}->Quote( $Param{Name}, 'Like' );

        # replace * with % and clean the string
        $Param{Name} =~ s{ \*+ }{%}xmsg;
        $Param{Name} =~ s{ %+ }{%}xmsg;

        $SQL .= " AND name LIKE '$Param{Name}' ";
    }

    $SQL .= ' ORDER BY name';

    # search service in db
    $Self->{DBObject}->Prepare( SQL => $SQL );

    my @ServiceList;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        push @ServiceList, $Row[0];
    }

    return @ServiceList;
}

=item CustomerUserServiceMemberList()

returns a list of customeruser/service members

    ServiceID: service id
    CustomerUserLogin: customer user login
    DefaultServices: activate or deactivate default services

    Result: HASH -> returns a hash of key => service id, value => service name
            Name -> returns an array of user names
            ID   -> returns an array of user ids

    Example (get services of customer user):

    $ServiceObject->CustomerUserServiceMemberList(
        CustomerUserLogin => 'Test',
        Result            => 'HASH',
        DefaultServices   => 0,
    );

    Example (get customer user of service):

    $ServiceObject->CustomerUserServiceMemberList(
        ServiceID => $ID,
        Result    => 'HASH',
    );

=cut

sub CustomerUserServiceMemberList {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{Result} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need Result!',
        );
        return;
    }
    if ( !$Param{ServiceID} && !$Param{CustomerUserLogin} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need ServiceID or CustomerUserLogin!',
        );
        return;
    }

    # set default
    if ( !defined $Param{DefaultServices} ) {
        $Param{DefaultServices} = 1;
    }

    # db quote
    for ( keys %Param ) {
        $Param{$_} = $Self->{DBObject}->Quote( $Param{$_} );
    }
    for (qw(ServiceID)) {
        $Param{$_} = $Self->{DBObject}->Quote( $Param{$_}, 'Integer' );
    }

    # create cache key
    my $CacheKey = 'CustomerUserServiceMemberList::' . $Param{Result} . '::';
    if ( $Param{ServiceID} ) {
        $CacheKey .= 'ServiceID::' . $Param{ServiceID};
    }
    elsif ( $Param{CustomerUserLogin} ) {
        $CacheKey .= 'CustomerUserLogin::' . $Param{CustomerUserLogin};
    }

    # check cache
    if ( $Param{ServiceID} || $Param{CustomerUserLogin} ) {
        if ( $Self->{ForceCache} ) {
            $Param{Cached} = $Self->{ForceCache};
        }
        if ( $Param{Cached} && $Self->{$CacheKey} ) {
            if ( ref( $Self->{$CacheKey} ) eq 'ARRAY' ) {
                return @{ $Self->{$CacheKey} };
            }
            elsif ( ref( $Self->{$CacheKey} ) eq 'HASH' ) {
                return %{ $Self->{$CacheKey} };
            }
        }
    }

    # sql
    my %Data;
    my @Name;
    my @ID;
    my $SQL = 'SELECT scu.service_id, scu.customer_user_login, s.name '
        . ' FROM '
        . ' service_customer_user scu, service s'
        . ' WHERE '
        . " s.valid_id IN ( ${\(join ', ', $Self->{ValidObject}->ValidIDsGet())} ) AND "
        . ' s.id = scu.service_id AND ';

    if ( $Param{ServiceID} ) {
        $SQL .= " scu.service_id = $Param{ServiceID}";
    }
    elsif ( $Param{CustomerUserLogin} ) {
        $SQL .= " scu.customer_user_login = '$Param{CustomerUserLogin}'";
    }

    $Self->{DBObject}->Prepare( SQL => $SQL );

    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {

        my $Key   = '';
        my $Value = '';
        if ( $Param{ServiceID} ) {
            $Key   = $Row[1];
            $Value = $Row[0];
        }
        else {
            $Key   = $Row[0];
            $Value = $Row[2];
        }

        # remember permissions
        if ( !defined $Data{$Key} ) {
            $Data{$Key} = $Value;
            push @Name, $Value;
            push @ID,   $Key;
        }
    }
    if ( $Param{CustomerUserLogin} && $Param{DefaultServices} && !keys(%Data) ) {
        %Data = $Self->CustomerUserServiceMemberList(
            CustomerUserLogin => '<DEFAULT>',
            Result            => 'HASH',
            DefaultServices   => 0,
        );
        for my $Key ( keys %Data ) {
            push @Name, $Data{$Key};
            push @ID,   $Key;
        }
    }

    # return result
    if ( $Param{Result} && $Param{Result} eq 'ID' ) {
        if ( $Param{ServiceID} || $Param{CustomerUserLogin} ) {

            # cache result
            $Self->{$CacheKey} = \@ID;
        }
        return @ID;
    }
    if ( $Param{Result} && $Param{Result} eq 'Name' ) {
        if ( $Param{ServiceID} || $Param{CustomerUserLogin} ) {

            # cache result
            $Self->{$CacheKey} = \@Name;
        }
        return @Name;
    }
    else {
        if ( $Param{ServiceID} || $Param{CustomerUserLogin} ) {

            # cache result
            $Self->{$CacheKey} = \%Data;
        }
        return %Data;
    }
}

=item CustomerUserServiceMemberAdd()

to add a member to a service

    $ServiceObject->CustomerUserServiceMemberAdd(
        CustomerUserLogin => 'Test1',
        ServiceID         => 6,
        Active            => 1,
        UserID            => 123,
    );

=cut

sub CustomerUserServiceMemberAdd {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Argument (qw(CustomerUserLogin ServiceID UserID)) {
        if ( !$Param{$Argument} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Need $Argument!",
            );
            return;
        }
    }

    # delete existing relation
    return if !$Self->{DBObject}->Do(
        SQL => 'DELETE FROM service_customer_user WHERE customer_user_login = ? AND service_id = ?',
        Bind => [ \$Param{CustomerUserLogin}, \$Param{ServiceID} ],
    );

    # return if relation is not active
    return if !$Param{Active};

    # insert new relation
    return $Self->{DBObject}->Do(
        SQL => 'INSERT INTO service_customer_user '
            . '(customer_user_login, service_id, create_time, create_by) '
            . 'VALUES (?, ?, current_timestamp, ?)',
        Bind => [ \$Param{CustomerUserLogin}, \$Param{ServiceID}, \$Param{UserID} ]
    );
}

=item ServicePreferencesSet()

set service preferences

    $ServiceObject->ServicePreferencesSet(
        ServiceID => 123,
        Key       => 'UserComment',
        Value     => 'some comment',
        UserID    => 123,
    );

=cut

sub ServicePreferencesSet {
    my $Self = shift;

    $Self->{CacheObject}->CleanUp(
        Type => 'Service',
    );

    return $Self->{PreferencesObject}->ServicePreferencesSet(@_);
}

=item ServicePreferencesGet()

get service preferences

    my %Preferences = $ServiceObject->ServicePreferencesGet(
        ServiceID => 123,
        UserID    => 123,
    );

=cut

sub ServicePreferencesGet {
    my $Self = shift;

    return $Self->{PreferencesObject}->ServicePreferencesGet(@_);
}

=item ServiceParentsGet()

return an ordered list all parent service IDs for the given service from the root parent to the
current service parent

    my $ServiceParentsList = $ServiceObject->ServiceParentsGet(
        ServiceID => 123,
        UserID    => 1,
    );

    returns

    $ServiceParentsList = [ 1, 2, ...];

=cut

sub ServiceParentsGet {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(UserID ServiceID)) {
        if ( !$Param{$Needed} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => 'Need $Needed!',
            );
            return;
        }
    }

    # get the list of services
    my $ServiceList = $Self->ServiceListGet(
        Valid  => 0,
        UserID => 1,
    );

    # get a service lookup table
    my %ServiceLoockup;
    SERVICE:
    for my $ServiceData ( @{$ServiceList} ) {
        next SERVICE if !$ServiceData;
        next SERVICE if !IsHashRefWithData($ServiceData);
        next SERVICE if !$ServiceData->{ServiceID};

        $ServiceLoockup{ $ServiceData->{ServiceID} } = $ServiceData;
    }

    # exit if ServiceID is invalid
    return if !$ServiceLoockup{ $Param{ServiceID} };

    # to store the return structure
    my @ServiceParents;

    # get the ServiceParentID from the requested service
    my $ServiceParentID = $ServiceLoockup{ $Param{ServiceID} }->{ParentID};

    # get all partents for the requested service
    while ($ServiceParentID) {

        # add service parent ID to the return structure
        push @ServiceParents, $ServiceParentID;

        # set next ServiceParentID (the parent of the current parent)
        $ServiceParentID = $ServiceLoockup{$ServiceParentID}->{ParentID} || 0;

    }

    # reverse the return array to get the list ordered from old to joung (in parent context)
    my @ReversedServiceParents = reverse @ServiceParents;

    return \@ReversedServiceParents;
}

1;

=back

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut

=head1 VERSION

$Revision: 1.51 $ $Date: 2012-06-04 21:28:03 $

=cut
