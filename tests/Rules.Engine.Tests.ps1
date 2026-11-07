BeforeDiscovery {
    $global = @{ Role = 'Global Administrator'; Assignment = 'Active'; 'Principal type' = 'user' }
    $member = @{ Type = 'Member'; Enabled = $true; 'Days inactive' = 1; 'Days since creation' = 400 }
    function Join-TcCase { param([hashtable]$A, [hashtable]$B) $c = @{}; foreach ($k in $A.Keys) { $c[$k] = $A[$k] }; foreach ($k in $B.Keys) { $c[$k] = $B[$k] }; $c }
    $inactive = Join-TcCase $member @{ UPN = 'old@a.example'; 'Days inactive' = 200 }
    $never = Join-TcCase $member @{ UPN = 'never@a.example'; 'Days inactive' = -1 }

    # One line per rule and case: the role it fires on, what the tenants hold, the severity and the item count.
    $script:RuleCases = @(
        # Entra ID
        @{ Id = 'ENT-INACTIVE'; On = 'S1'; Severity = 'High'; Category = 'Decision needed'; Items = 2; Given = @{ S1 = @{ users = @($inactive, $never, (Join-TcCase $member @{ UPN = 'on@a.example' })) } } }
        @{ Id = 'ENT-INACTIVE'; On = 'Target'; Severity = 'Medium'; Category = 'Cleanup'; Items = 1; Given = @{ Target = @{ users = @($inactive) } } }
        @{ Id = 'ENT-DISABLED-LICENSED'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ users = @(@{ UPN = 'x'; Enabled = $false; 'License count' = 2; Licenses = 'A; B' }) } } }
        @{ Id = 'ENT-GUESTS'; On = 'S1'; Severity = 'Medium'; Category = 'Recreate in target'; Items = 2; Given = @{ S1 = @{ users = @(@{ UPN = 'g1'; Type = 'Guest'; 'Invitation state' = 'PendingAcceptance' }, @{ UPN = 'g2'; Type = 'Guest'; 'Days inactive' = 2 }) } } }
        @{ Id = 'ENT-GUESTS'; On = 'Target'; Severity = 'Low'; Category = 'Cleanup'; Items = 1; Given = @{ Target = @{ users = @(@{ UPN = 'g1'; Type = 'Guest'; 'Days inactive' = -1 }, @{ UPN = 'g2'; Type = 'Guest'; 'Days inactive' = 2 }) } } }
        @{ Id = 'ENT-ADMINS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ adminRoles = @(Join-TcCase $global @{ Principal = 'a@a.example' }) } } }
        @{ Id = 'ENT-ADMINS'; On = 'S1'; Severity = 'High'; Items = 2; Given = @{ S1 = @{ adminRoles = @((Join-TcCase $global @{ Principal = 'a@a.example' }), (Join-TcCase $global @{ Principal = 'v_x#EXT#@a' })) } } }
        @{ Id = 'ENT-ADMINS'; On = 'S1'; Severity = 'High'; Items = 9; Given = @{ S1 = @{ adminRoles = @(1..9 | ForEach-Object { Join-TcCase $global @{ Principal = "a$_@a.example" } }) } } }
        @{ Id = 'ENT-MFA'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ conditionalAccess = @(@{ Name = 'p'; State = 'enabledForReportingButNotEnforced' }) } } }
        @{ Id = 'ENT-MFA'; On = 'Target'; Severity = 'Critical'; Items = 0; Given = @{ Target = @{ conditionalAccess = @() } } }
        @{ Id = 'ENT-LEGACY-AUTH'; On = 'S1'; Severity = 'High'; Items = 0; Given = @{ S1 = @{ conditionalAccess = @() } } }
        @{ Id = 'ENT-MFA-REGISTRATION'; On = 'Target'; Severity = 'High'; Category = 'Security'; Items = 1; Given = @{ Target = @{ mfaRegistrations = @(@{ UPN = 'a'; Type = 'member'; 'MFA registered' = $false }, @{ UPN = 'b'; Type = 'member'; 'MFA registered' = $false }); users = @(Join-TcCase $member @{ UPN = 'a' }) } } }
        @{ Id = 'ENT-MFA-REGISTRATION'; On = 'S1'; Severity = 'Info'; Category = 'Information'; Items = 2; Given = @{ S1 = @{ mfaRegistrations = @(@{ UPN = 'a'; Type = 'member'; 'MFA registered' = $false }, @{ UPN = 'b'; Type = 'member'; 'MFA registered' = $false }) } } }
        @{ Id = 'ENT-GROUP-CREATION'; On = 'Target'; Severity = 'Medium'; Items = 0; Given = @{ Target = @{ groupSettings = @() } } }
        @{ Id = 'ENT-AUTHORIZATION'; On = 'S1'; Severity = 'Low'; Items = 0; Given = @{ S1 = @{ securitySettings = @(@{ Setting = 'Invitations allowed from'; Value = 'everyone' }) } } }
        @{ Id = 'ENT-AUTHORIZATION'; On = 'S1'; Severity = 'Low'; Items = 0; Given = @{ S1 = @{ securitySettings = @(@{ Setting = 'User permissions.allowedToCreateApps'; Value = $true }) } } }
        @{ Id = 'ENT-SECRETS'; On = 'S1'; Severity = 'Medium'; Items = 2; Given = @{ S1 = @{ applications = @(@{ Name = 'a'; Expired = 1 }, @{ Name = 'b'; Expired = 0; 'Days to expiry' = 60 }, @{ Name = 'c'; Expired = 0; 'Days to expiry' = 61 }) } } }
        @{ Id = 'ENT-THIRD-PARTY-APPS'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ servicePrincipals = @(@{ Name = 'Vendor'; Origin = 'Third party'; Enabled = $true }, @{ Name = 'Off'; Origin = 'Third party'; Enabled = $false }, @{ Name = 'Own'; Origin = 'Internal'; Enabled = $true }) } } }
        @{ Id = 'ENT-APP-REGISTRATIONS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ applications = @(@{ Name = 'a'; Audience = 'x'; Created = 'y' }) } } }
        @{ Id = 'ENT-SYNC-SOURCE'; On = 'S1'; Severity = 'High'; Items = 0; Given = @{ S1 = @{ organizationSettings = @(@{ Setting = 'AD sync enabled'; Value = $true }, @{ Setting = 'Days since last sync'; Value = 0 }) } } }
        @{ Id = 'ENT-SYNC-TARGET'; On = 'Target'; Severity = 'High'; Items = 0; Given = @{ Target = @{ organizationSettings = @(@{ Setting = 'AD sync enabled'; Value = $true }, @{ Setting = 'Days since last sync'; Value = 3 }) } } }
        @{ Id = 'ENT-LICENSE-ERRORS'; On = 'S1'; Severity = 'Low'; Items = 1; Given = @{ S1 = @{ users = @(@{ UPN = 'a'; 'License errors' = 2 }) } } }
        @{ Id = 'ENT-STALE-DEVICES'; On = 'S1'; Severity = 'Low'; Items = 5; Given = @{ S1 = @{ devices = @(1..5 | ForEach-Object { @{ Name = "d$_"; OS = 'Windows'; 'Days inactive' = 90 } }) } } }
        @{ Id = 'ENT-BUSINESS-CAP'; On = 'Target'; Severity = 'High'; Items = 0; Given = @{ Target = @{ licenses = @(@{ SKU = 'SPB'; Purchased = 290; Available = 2 }) } } }
        @{ Id = 'ENT-LEGACY-SIGN-INS'; On = 'S1'; Severity = 'High'; Items = 2; Given = @{ S1 = @{ legacySignIns = @(@{ UPN = 'a'; Client = 'IMAP4'; 'Sign-ins' = 3 }, @{ UPN = 'a'; Client = 'POP3'; 'Sign-ins' = 1 }) } } }
        @{ Id = 'ENT-COUNTRIES'; On = 'S1'; Severity = 'Info'; Items = 1; Given = @{ S1 = @{ organizationSettings = @(@{ Setting = 'Country'; Value = 'CA' }); signInSummary = @(@{ Dimension = 'Country'; Value = 'CA'; 'Sign-ins' = 9 }, @{ Dimension = 'Country'; Value = 'FR'; 'Sign-ins' = 3 }, @{ Dimension = 'Country'; Value = '(empty)' }) } } }
        @{ Id = 'ENT-APP-PERMISSIONS'; On = 'S1'; Severity = 'High'; Category = 'Recreate in target'; Items = 1; Given = @{ S1 = @{ applicationPermissions = @(@{ Application = 'a'; Resource = 'Graph'; Permission = 'Mail.Read' }, @{ Application = 'b'; Resource = 'Graph'; Permission = 'User.Read' }) } } }
        @{ Id = 'ENT-APP-PERMISSIONS'; On = 'Target'; Severity = 'Medium'; Category = 'Security'; Items = 1; Given = @{ Target = @{ applicationPermissions = @(@{ Application = 'a'; Resource = 'Graph'; Permission = 'Sites.Read.All' }) } } }
        @{ Id = 'ENT-RISK'; On = 'S1'; Severity = 'Critical'; Items = 1; Given = @{ S1 = @{ riskyUsers = @(@{ UPN = 'a'; Level = 'high'; State = 'atRisk' }) } } }
        @{ Id = 'ENT-RISK'; On = 'Target'; Severity = 'High'; Items = 1; Given = @{ Target = @{ riskyUsers = @(@{ UPN = 'a'; Level = 'high'; State = 'atRisk' }) } } }
        @{ Id = 'ENT-SYNC-ERRORS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ users = @(@{ UPN = 'a'; 'Sync errors' = 1 }) } } }

        # Exchange Online
        @{ Id = 'EXO-FORWARDING'; On = 'S1'; Severity = 'High'; Items = 2; Given = @{ S1 = @{ mailboxes = @(@{ UPN = 'a'; 'SMTP forwarding' = 'smtp:x@y.example' }, @{ UPN = 'b'; 'Internal forwarding' = 'c' }, @{ UPN = 'c' }) } } }
        @{ Id = 'EXO-ARCHIVES'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ mailboxes = @(@{ UPN = 'a'; Archive = $true }); archives = @(@{ UPN = 'a'; 'Size GB' = 5.5 }) } } }
        @{ Id = 'EXO-HOLDS'; On = 'S1'; Severity = 'High'; Items = 3; Given = @{ S1 = @{ mailboxes = @(@{ UPN = 'a'; 'Litigation hold' = $true }, @{ UPN = 'b'; Holds = 1 }); inactiveMailboxes = @(@{ Address = 'c' }) } } }
        @{ Id = 'EXO-LARGE-MAILBOXES'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ mailboxUsage = @(@{ UPN = 'a'; Type = 'User'; 'Size GB' = 45 }, @{ UPN = 'b'; Type = 'User'; 'Size GB' = 44.9 }) } } }
        @{ Id = 'EXO-LARGE-MAILBOXES'; On = 'Target'; Severity = 'Low'; Items = 1; Given = @{ Target = @{ mailboxUsage = @(@{ UPN = 'a'; Type = 'User'; 'Size GB' = 45 }) } } }
        @{ Id = 'EXO-SHARED-LICENSED'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ mailboxUsage = @(@{ UPN = 'a'; Type = 'Shared'; 'Size GB' = 45 }, @{ UPN = 'b'; Type = 'User'; 'Size GB' = 45 }) } } }
        @{ Id = 'EXO-RULES'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ transportRules = @(@{ Name = 'a'; State = 'Enabled' }, @{ Name = 'b'; State = 'Disabled' }) } } }
        @{ Id = 'EXO-CONNECTORS'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ connectors = @(@{ Name = 'a'; Enabled = $true }, @{ Name = 'b'; Enabled = $false }) } } }
        @{ Id = 'EXO-JOURNAL'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ journalRules = @(@{ Name = 'a'; 'Journal address' = 'x' }) } } }
        @{ Id = 'EXO-RECIPIENTS'; On = 'S1'; Severity = 'Medium'; Items = 2; Given = @{ S1 = @{ distributionGroups = @(@{ Name = 'a'; Address = 'x' }); dynamicGroups = @(@{ Name = 'b' }); contacts = @(@{ Name = 'c' }) } } }
        @{ Id = 'EXO-PERMISSIONS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ mailboxPermissions = @(@{ Mailbox = 'a'; User = 'b'; Right = 'FullAccess' }) } } }
        @{ Id = 'EXO-DKIM'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ dkim = @(@{ Domain = 'a.example'; Enabled = $false }, @{ Domain = 'a.onmicrosoft.com'; Enabled = $false }) } } }
        @{ Id = 'EXO-DKIM'; On = 'Target'; Severity = 'High'; Items = 1; Given = @{ Target = @{ dkim = @(@{ Domain = 'a.example'; Enabled = $false }) } } }
        @{ Id = 'EXO-AUDIT'; On = 'S1'; Severity = 'High'; Items = 0; Given = @{ S1 = @{ exchangeSettings = @(@{ Setting = 'Unified audit log enabled'; Value = $false }) } } }
        @{ Id = 'EXO-HYBRID'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ exchangeHybrid = @(@{ Item = 'a'; Name = 'b'; Detail = 'c' }) } } }
        @{ Id = 'EXO-HYBRID'; On = 'Target'; Severity = 'Medium'; Items = 1; Given = @{ Target = @{ exchangeHybrid = @(@{ Item = 'a'; Name = 'b'; Detail = 'c' }) } } }
        @{ Id = 'EXO-AUTO-FORWARD'; On = 'S1'; Severity = 'Low'; Items = 0; Given = @{ S1 = @{ remoteDomains = @(@{ Domain = '*'; 'Auto-forward' = $true }) } } }
        @{ Id = 'EXO-PROTOCOLS'; On = 'S1'; Severity = 'Medium'; Items = 3; Given = @{ S1 = @{ mailboxProtocols = @(@{ Mailbox = 'a'; POP = $true }, @{ Mailbox = 'b'; IMAP = $true }, @{ Mailbox = 'c'; 'Authenticated SMTP' = $true }, @{ Mailbox = 'd'; 'Authenticated SMTP' = 'Per organization' }) } } }
        @{ Id = 'EXO-MOBILE'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ mobileDevices = @(@{ User = 'a'; Model = 'm'; System = 'iOS 17'; Client = 'EAS' }) } } }
        @{ Id = 'EXO-INBOX-RULES'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ inboxRules = @(@{ Mailbox = 'a'; Rule = 'r'; To = 'x'; External = $true }, @{ Mailbox = 'b'; Rule = 's'; To = 'y'; External = $false }) } } }
        @{ Id = 'EXO-ROOMS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ roomsAndEquipment = @(@{ Resource = 'a'; Processing = 'p'; 'Booking window (days)' = 1; Delegates = 0 }) } } }
        @{ Id = 'EXO-PUBLIC-FOLDERS'; On = 'S1'; Severity = 'High'; Category = 'Migration complexity'; Items = 2; Given = @{ S1 = @{ publicFolders = @(@{ Path = '\a'; Email = $true }, @{ Path = '\b'; Email = $false }) } } }
        @{ Id = 'EXO-PUBLIC-FOLDERS'; On = 'Target'; Severity = 'Medium'; Items = 1; Given = @{ Target = @{ publicFolders = @(@{ Path = '\a'; Email = $false }) } } }

        # SharePoint and OneDrive
        @{ Id = 'SPO-SHARING'; On = 'S1'; Severity = 'Medium'; Items = 0; Given = @{ S1 = @{ sharePointSettings = @(@{ Setting = 'SharingCapability'; Value = 'ExternalUserAndGuestSharing' }) } } }
        @{ Id = 'SPO-SHARING'; On = 'Target'; Severity = 'High'; Items = 1; Given = @{ Target = @{ sites = @(@{ Url = 'https://a'; Sharing = 'ExternalUserAndGuestSharing'; 'Storage MB' = 50; 'Days inactive' = 1 }) } } }
        @{ Id = 'SPO-INACTIVE'; On = 'S1'; Severity = 'Medium'; Items = 3; Given = @{ S1 = @{ sites = @(@{ Url = 'https://a'; Template = 'STS#3'; 'Storage MB' = 1; 'Days inactive' = 30 }, @{ Url = 'https://b/'; Template = 'STS#3'; 'Storage MB' = 900; 'Days inactive' = 1 }, @{ Url = 'https://c'; Template = 'STS#3'; 'Storage MB' = 900; 'Days inactive' = 365 }, @{ Url = 'https://d'; Template = 'APPCATALOG#0'; 'Storage MB' = 1; 'Days inactive' = 900 }); siteUsage = @(@{ Url = 'HTTPS://B'; Files = 0 }) } } }
        @{ Id = 'SPO-INACTIVE'; On = 'Target'; Severity = 'Low'; Items = 1; Given = @{ Target = @{ sites = @(@{ Url = 'https://a'; Template = 'STS#3'; 'Storage MB' = 900; 'Days inactive' = 400 }) } } }
        @{ Id = 'SPO-LARGE-SITES'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ sites = @(@{ Url = 'https://a'; 'Storage MB' = 102400; 'Days inactive' = 1 }, @{ Url = 'https://b'; 'Storage MB' = 100; 'Days inactive' = 1 }) } } }
        @{ Id = 'SPO-CLASSIC'; On = 'S1'; Severity = 'Medium'; Items = 2; Given = @{ S1 = @{ sites = @(@{ Url = 'https://a'; Template = 'STS#0'; 'Storage MB' = 50; 'Days inactive' = 1 }, @{ Url = 'https://b'; Template = 'STS#0'; Group = 'g'; 'Storage MB' = 50; 'Days inactive' = 1 }, @{ Url = 'https://c'; Template = 'GROUP#0'; 'Custom scripts' = $true; 'Storage MB' = 50; 'Days inactive' = 1 }) } } }
        @{ Id = 'SPO-HUBS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ sites = @(@{ Url = 'https://a'; 'Storage MB' = 50; 'Days inactive' = 1 }); hubSites = @(@{ Url = 'https://a'; 'Associated sites' = 1 }) } } }
        @{ Id = 'SPO-LABELS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ sites = @(@{ Url = 'https://a'; Label = 'Confidential'; 'Storage MB' = 50; 'Days inactive' = 1 }) } } }
        @{ Id = 'SPO-CUSTOMIZATIONS'; On = 'S1'; Severity = 'Medium'; Items = 2; Given = @{ S1 = @{ sharePointCustomizations = @(@{ Type = 'Site design'; Name = 'a' }, @{ Type = 'Asset library'; Name = 'b' }, @{ Type = 'App catalog'; Name = 'c' }) } } }
        @{ Id = 'SPO-CUSTOMIZATIONS'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ sharePointCustomizations = @(@{ Type = 'SPFx app'; Name = 'a' }) } } }
        @{ Id = 'SPO-TERMS'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ termStore = @(@{ Group = 'g'; 'Term set' = 't'; Terms = 2; 'System or collection' = $false }, @{ Group = 'h'; 'Term set' = 'u'; Terms = 2; 'System or collection' = $true }) } } }
        @{ Id = 'SPO-ONEDRIVE'; On = 'S1'; Severity = 'Info'; Items = 0; Given = @{ S1 = @{ oneDrive = @(@{ Url = 'https://o'; Owner = 'A'; 'Storage MB' = 10 }); users = @(@{ UPN = 'a'; Enabled = $true }) } } }
        @{ Id = 'SPO-ONEDRIVE'; On = 'S1'; Severity = 'Medium'; Items = 2; Given = @{ S1 = @{ oneDrive = @(@{ Url = 'https://o'; Owner = 'gone'; 'Storage MB' = 10 }, @{ Url = 'https://p'; Owner = 'a'; 'Storage MB' = 102400 }); users = @(@{ UPN = 'a'; Enabled = $true }) } } }
        @{ Id = 'SPO-EXTERNAL'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ sharePointExternalUsers = @(@{ Name = 'a'; Email = 'b'; 'Invited by' = 'c' }) } } }
        @{ Id = 'AUT-CONCEALED-REPORTS'; On = 'S1'; Severity = 'Medium'; Items = 0; Given = @{ S1 = @{ reportSettings = @(@{ Setting = 'Names concealed in reports'; Value = $true }) } } }

        # Teams
        @{ Id = 'TMS-OWNERS'; On = 'Target'; Severity = 'Medium'; Items = 2; Given = @{ Target = @{ teamComposition = @(@{ Team = 'a'; Owners = 0 }, @{ Team = 'b'; Owners = 1 }, @{ Team = 'c'; Owners = 2 }) } } }
        @{ Id = 'TMS-CHANNELS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ teamComposition = @(@{ Team = 'a'; Owners = 2; 'Private channels' = 1; 'Shared channels' = 0 }) } } }
        @{ Id = 'TMS-CHANNELS'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ teamComposition = @(@{ Team = 'a'; Owners = 2; 'Private channels' = 0; 'Shared channels' = 1 }) } } }
        @{ Id = 'TMS-GUESTS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ teamComposition = @(@{ Team = 'a'; Owners = 2; Guests = 3 }) } } }
        @{ Id = 'TMS-ARCHIVED'; On = 'S1'; Severity = 'Low'; Items = 1; Given = @{ S1 = @{ teams = @(@{ Name = 'a'; Archived = $true }, @{ Name = 'b'; Archived = $false }) } } }
        @{ Id = 'TMS-POLICIES'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ teamsPolicies = @(@{ Type = 'T'; Identity = 'Tag:a'; Custom = $true }, @{ Type = 'T'; Identity = 'Global'; Custom = $false }); teamsUsers = @(@{ UPN = 'a'; Policies = 'T=a; U=b' }) } } }
        @{ Id = 'TMS-APPS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ teamsApps = @(@{ Name = 'a'; Version = '1' }) } } }
        @{ Id = 'TMS-DEVICES'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ teamsDevices = @(@{ Type = 'ipPhone'; Model = 'm'; User = 'u' }) } } }

        # Teams Phone
        @{ Id = 'TEL-NUMBERS'; On = 'S1'; Severity = 'Critical'; Items = 3; Given = @{ S1 = @{ phoneNumbers = @(@{ Number = '1'; Type = 'CallingPlan'; Assignment = 'Unassigned' }, @{ Number = '2'; Type = 'DirectRouting'; Assignment = 'UserAssigned' }, @{ Number = '3'; Type = 'OperatorConnect'; Assignment = 'UserAssigned' }) } } }
        @{ Id = 'TEL-USERS'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ teamsUsers = @(@{ UPN = 'a'; 'Enterprise Voice' = $true; Number = '1' }, @{ UPN = 'b'; 'Enterprise Voice' = $false }) } } }
        @{ Id = 'TEL-VOICE-APPS'; On = 'S1'; Severity = 'High'; Items = 3; Given = @{ S1 = @{ autoAttendants = @(@{ Name = 'a' }); callQueues = @(@{ Name = 'b' }); resourceAccounts = @(@{ UPN = 'c' }) } } }
        @{ Id = 'TEL-EMERGENCY'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ emergencyAddresses = @(@{ Description = 'a'; Address = 'b'; City = 'c'; Validation = 'd' }) } } }
        @{ Id = 'TEL-DIRECT-ROUTING'; On = 'S1'; Severity = 'Critical'; Category = 'Migration blocker'; Items = 1; Given = @{ S1 = @{ pstnGateways = @(@{ FQDN = 'sbc.alpine.example'; Port = 5061; Enabled = $true }) } } }
        @{ Id = 'TEL-DIRECT-ROUTING'; On = 'S1'; Severity = 'High'; Category = 'Recreate in target'; Items = 1; Given = @{ S1 = @{ pstnGateways = @(@{ FQDN = 'sbc.carrier.example'; Port = 5061; Enabled = $true }) } } }
        @{ Id = 'TEL-DIAL-PLANS'; On = 'S1'; Severity = 'Medium'; Items = 3; Given = @{ S1 = @{ dialPlans = @(@{ Name = 'Tag:a'; Rules = 1 }, @{ Name = 'Global'; Rules = 1 }); voiceRoutes = @(@{ Name = 'b'; Pattern = 'p' }); voiceRoutingPolicies = @(@{ Name = 'Tag:c' }, @{ Name = 'Global' }) } } }
        @{ Id = 'TEL-CONFERENCING'; On = 'S1'; Severity = 'Low'; Items = 1; Given = @{ S1 = @{ conferenceBridges = @(@{ Name = 'a'; 'Default number' = '1' }, @{ Name = 'b' }) } } }
        @{ Id = 'TEL-CALLING-SETTINGS'; On = 'S1'; Severity = 'Medium'; Items = 2; Given = @{ S1 = @{ userCallingSettings = @(@{ UPN = 'a'; Forwarding = 'x' }, @{ UPN = 'b'; 'Call group' = 'y' }, @{ UPN = 'c' }) } } }
        @{ Id = 'TEL-ROUTING-TARGET'; On = 'Target'; Severity = 'Info'; Items = 2; Given = @{ Target = @{ domains = @(@{ Domain = 'sbc.summit.example' }, @{ Domain = 'other.example' }); pstnGateways = @(@{ FQDN = 'sbc.summit.example' }) } } }
        @{ Id = 'TEL-SCHEDULES'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ phoneSchedules = @(@{ Name = 'a'; Type = 'b'; 'Used by' = 1 }) } } }
        @{ Id = 'TEL-NETWORK'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ phoneNetworkTopology = @(@{ Type = 'a'; Name = 'b'; Detail = 'c' }) } } }

        # Intune
        @{ Id = 'INT-AUTOPILOT'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ autopilotDevices = @(@{ 'Serial number' = 'a'; Model = 'b'; 'Group tag' = 'c' }) } } }
        @{ Id = 'INT-STALE'; On = 'S1'; Severity = 'Low'; Items = 1; Given = @{ S1 = @{ managedDevices = @(@{ Name = 'a'; OS = 'w'; 'Days inactive' = 90 }, @{ Name = 'b'; OS = 'w'; 'Days inactive' = 89 }) } } }
        @{ Id = 'INT-NONCOMPLIANT'; On = 'Target'; Severity = 'Medium'; Items = 1; Given = @{ Target = @{ managedDevices = @(@{ Name = 'a'; OS = 'w'; Compliance = 'noncompliant'; User = 'u' }) } } }
        @{ Id = 'INT-POLICIES'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ intunePolicies = @(@{ Category = 'a'; Name = 'b'; Platform = 'c' }) } } }
        @{ Id = 'INT-APPS'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ intuneApps = @(@{ Name = 'a'; Type = 'win32LobApp'; Assigned = $true }, @{ Name = 'b'; Type = 'webApp'; Assigned = $true }, @{ Name = 'c'; Type = 'win32LobApp'; Assigned = $false }) } } }
        @{ Id = 'INT-MAM'; On = 'S1'; Severity = 'Low'; Items = 1; Given = @{ S1 = @{ appProtectionPolicies = @(@{ Name = 'a' }) } } }
        @{ Id = 'INT-CONNECTORS'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ intuneConnectors = @(@{ Type = 'Apple MDM certificate (APNs)'; Name = 'a'; Account = 'b'; 'Days remaining' = 300 }) } } }
        @{ Id = 'INT-CONNECTORS'; On = 'Target'; Severity = 'High'; Items = 1; Given = @{ Target = @{ intuneConnectors = @(@{ Type = 'Apple MDM certificate (APNs)'; Account = 'b'; 'Days remaining' = 45 }, @{ Type = 'Apple MDM certificate (APNs)'; Account = 'c'; 'Days remaining' = 46 }) } } }

        # Purview
        @{ Id = 'PUR-ENCRYPTION'; On = 'S1'; Severity = 'Critical'; Items = 1; Given = @{ S1 = @{ sensitivityLabels = @(@{ Name = 'a'; 'Display name' = 'A'; Encryption = $true; Disabled = $false }, @{ Name = 'b'; 'Display name' = 'B'; Encryption = $true; Disabled = $true }) } } }
        @{ Id = 'PUR-LABELS'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ sensitivityLabels = @(@{ Name = 'a'; 'Display name' = 'A'; Scope = 'File' }, @{ Name = 'b'; 'Display name' = 'B'; Scope = 'File' }) }; Target = @{ sensitivityLabels = @(@{ Name = 'x'; 'Display name' = 'b' }) } } }
        @{ Id = 'PUR-RETENTION'; On = 'S1'; Severity = 'High'; Items = 2; Given = @{ S1 = @{ retentionPolicies = @(@{ Name = 'a'; Enabled = $true; Locations = 'x' }, @{ Name = 'b'; Enabled = $false }); ediscoveryCases = @(@{ Name = 'c'; Status = 'Active'; Holds = 1 }, @{ Name = 'd'; Status = 'Closed' }) } } }
        @{ Id = 'PUR-DLP'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ dlpPolicies = @(@{ Name = 'a'; Enabled = $true; Mode = 'm'; Workloads = 'w' }) } } }

        # Power Platform, Azure and other services
        @{ Id = 'POW-RESOURCES'; On = 'S1'; Severity = 'High'; Items = 1; Given = @{ S1 = @{ powerApps = @(@{ Name = 'a'; Owner = 'b' }); powerEnvironments = @(@{ Name = 'Default'; Default = $true; Dataverse = $false }) } } }
        @{ Id = 'POW-RESOURCES'; On = 'S1'; Severity = 'Critical'; Items = 1; Given = @{ S1 = @{ powerFlows = @(@{ Name = 'a'; Owner = 'b'; Enabled = $true }); powerEnvironments = @(@{ Name = 'Production'; Default = $false; Dataverse = $true }) } } }
        @{ Id = 'AZR-SUBSCRIPTIONS'; On = 'S1'; Severity = 'High'; Items = 2; Given = @{ S1 = @{ azureSubscriptions = @(@{ Name = 'a'; State = 'Enabled'; 'RBAC assignments' = 1 }); azureResources = @(@{ Subscription = 'a'; Count = 1; Type = 'Microsoft.DesktopVirtualization/hostPools' }) } } }
        @{ Id = 'AUT-SERVICES'; On = 'S1'; Severity = 'Medium'; Items = 3; Given = @{ S1 = @{ bookings = @(@{ Name = 'a' }); vivaCommunities = @(@{ Name = 'b' }); plannerPlans = @(@{ Group = 'c'; Plan = 'd' }) } } }
        @{ Id = 'AUT-COPILOT'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ licenses = @(@{ SKU = 'Microsoft_365_Copilot'; Consumed = 2 }, @{ SKU = 'Other'; Consumed = 2 }) } } }
        @{ Id = 'AUT-SECURE-SCORE'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ secureScore = @(@{ Setting = 'Percentage'; Value = 39 }, @{ Setting = 'Current score'; Value = 39 }, @{ Setting = 'Maximum score'; Value = 100 }); secureScoreActions = @(@{ Control = 'a'; 'Possible gain' = 1; 'User impact' = 'Low' }) } } }
        @{ Id = 'AUT-SECURE-SCORE'; On = 'Target'; Severity = 'Info'; Items = 0; Given = @{ Target = @{ secureScore = @(@{ Setting = 'Percentage'; Value = 40 }) } } }

        # Domains and DNS
        @{ Id = 'DNS-SPF'; On = 'S1'; Severity = 'High'; Items = 2; Given = @{ S1 = @{ dnsSummary = @(@{ Domain = 'a'; SPF = 'Missing' }, @{ Domain = 'b'; SPF = 'Multiple (invalid)' }, @{ Domain = 'c'; SPF = 'v=spf1' }) } } }
        @{ Id = 'DNS-DMARC'; On = 'S1'; Severity = 'Medium'; Items = 2; Given = @{ S1 = @{ dnsSummary = @(@{ Domain = 'a'; DMARC = 'Missing' }, @{ Domain = 'b'; DMARC = 'none' }, @{ Domain = 'c'; DMARC = 'reject' }) } } }
        @{ Id = 'DNS-TTL'; On = 'S1'; Severity = 'High'; Category = 'Preparation'; Items = 1; Given = @{ S1 = @{ dnsSummary = @(@{ Domain = 'a'; 'MX TTL' = 301 }, @{ Domain = 'b'; 'MX TTL' = 300 }, @{ Domain = 'c' }) } } }
        @{ Id = 'DNS-HOST'; On = 'S1'; Severity = 'Info'; Items = 1; Given = @{ S1 = @{ dnsSummary = @(@{ Domain = 'a'; 'DNS host' = 'h'; 'Inbound mail flow' = 'f' }) } } }
        @{ Id = 'DNS-SKYPE'; On = 'S1'; Severity = 'Medium'; Category = 'Cutover'; Items = 1; Given = @{ S1 = @{ dnsSummary = @(@{ Domain = 'a'; 'Teams or legacy Skype' = $true }) } } }
        @{ Id = 'DNS-GATEWAY'; On = 'S1'; Severity = 'Medium'; Items = 1; Given = @{ S1 = @{ dnsSummary = @(@{ Domain = 'a'; 'Inbound mail flow' = 'Third-party gateway'; MX = 'm' }) } } }
    )
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')

    function Get-TcFindingId { param($RuleSet) @($RuleSet['findings'] | ForEach-Object { $_['id'] }) }
}

Describe 'Invoke-TcRuleSet' {
    It 'returns findings, measures, setting gaps, unread tables and errors' {
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot)
        foreach ($key in 'findings', 'measures', 'settingGaps', 'unread', 'errors') { $result.Contains($key) | Should -BeTrue -Because "$key is part of the result" }
    }

    It 'runs the same rule set twice and leaves no state behind' {
        $snapshot = New-TcRuleSnapshot -Given @{ S1 = @{ riskyUsers = @(@{ UPN = 'a'; Level = 'high'; State = 'atRisk' }) } }
        $first = Invoke-TcRuleSet -Snapshot $snapshot
        $second = Invoke-TcRuleSet -Snapshot $snapshot
        ($first | ConvertTo-Json -Depth 8) | Should -Be ($second | ConvertTo-Json -Depth 8)
        InModuleScope TenantConverge { $script:TcRuleRun | Should -BeNullOrEmpty }
    }

    It 'gives an empty result for a snapshot with no table, without any error' {
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot)
        @($result['findings'] | Where-Object { $_['id'] -notin 'CON-DOMAINS' }).Count | Should -Be 0
        @($result['errors']).Count | Should -Be 0
    }

    It 'sorts findings by severity, workload and title' {
        $given = @{ S1 = @{ riskyUsers = @(@{ UPN = 'a'; Level = 'high'; State = 'atRisk' }); mailboxPermissions = @(@{ Mailbox = 'a'; User = 'b'; Right = 'FullAccess' }); dnsSummary = @(@{ Domain = 'a'; SPF = 'Missing' }) } }
        $severities = @((Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given))['findings'] | ForEach-Object { $_['severity'] })
        $severities | Select-Object -First 1 | Should -Be 'Critical'
        $severities | Select-Object -Last 1 | Should -Be 'Info'
    }

    It 'turns a failing rule into a reported error and keeps going' {
        Mock -ModuleName TenantConverge Get-TcRuleThreshold { 90 }
        Mock -ModuleName TenantConverge Get-TcRuleThreshold { throw 'Broken column' } -ParameterFilter { $Name -eq 'inactiveDays' }
        $given = @{ S1 = @{ users = @(@{ UPN = 'a'; Type = 'Member'; Enabled = $true; 'Days inactive' = 100 }); riskyUsers = @(@{ UPN = 'a'; Level = 'high'; State = 'atRisk' }) } }
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given)
        @($result['errors']).Count | Should -BeGreaterThan 0
        $result['errors'][0]['message'] | Should -Match 'Broken column'
        Get-TcFindingId $result | Should -Contain 'ENT-RISK'
    }

    It 'reads negative numbers, as a clock behind gives them' {
        InModuleScope TenantConverge {
            Get-TcRowInteger @{ n = -1 } 'n' | Should -Be -1
            Get-TcRowInteger @{ n = '-12' } 'n' | Should -Be -12
            Get-TcRowInteger @{ n = 7 } 'n' | Should -Be 7
            Get-TcRowInteger @{ n = '' } 'n' | Should -Be 0
            Get-TcRowInteger @{ n = $null } 'n' | Should -Be 0
            Get-TcRowInteger @{} 'n' | Should -Be 0
            Get-TcRowNumber @{ n = -1.5 } 'n' | Should -Be -1.5
            Get-TcRowNumber @{ n = '-2.5' } 'n' | Should -Be -2.5
            Get-TcRowNumber @{ n = '' } 'n' | Should -Be 0
        }
    }

    It 'keeps ENT-INACTIVE running on an account created ahead of the clock' {
        $given = @{ S1 = @{ users = @(@{ UPN = 'a'; Type = 'Member'; Enabled = $true; 'Days inactive' = 100; 'Days since creation' = -1 }, @{ UPN = 'b'; Type = 'Member'; Enabled = $true; 'Days inactive' = 100; 'Days since creation' = 200 }) } }
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given)
        @($result['errors']).Count | Should -Be 0 -Because (@($result['errors']) | ConvertTo-Json -Depth 3)
        (@($result['findings'] | Where-Object { $_['id'] -eq 'ENT-INACTIVE' }))[0]['itemCount'] | Should -Be 1
    }

    It 'keeps going when one measure meets a bad value, and leaves that value empty' {
        $given = @{ S1 = @{ sites = @(@{ Url = 'https://x'; Path = '/'; 'Storage MB' = 'not a number'; 'Days inactive' = 1 }); teams = @(@{ Name = 'a' }) } }
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given)
        $bad = @($result['errors'] | Where-Object { $_['role'] -eq 'S1' -and $_['workload'] -eq 'SharePoint and OneDrive' })
        $bad.Count | Should -BeGreaterThan 0
        ($result['measures'] | Where-Object { $_['label'] -eq 'Site volume (GB)' })['values']['S1'] | Should -BeNullOrEmpty
        ($result['measures'] | Where-Object { $_['label'] -eq 'Teams' })['values']['S1'] | Should -Be 1
    }

    It 'keeps going when one table of setting gaps stops' {
        Mock -ModuleName TenantConverge Get-TcRuleRow { }
        Mock -ModuleName TenantConverge Get-TcRuleRow { throw 'Bad value' } -ParameterFilter { $Table -eq 'teamsSettings' -and $Role -eq 'S1' }
        Mock -ModuleName TenantConverge Get-TcRuleRow { @(@{ Setting = 'SharingCapability'; Value = $Role }) } -ParameterFilter { $Table -eq 'sharePointSettings' }
        $given = @{ Target = @{ teamsSettings = @(); sharePointSettings = @() }; S1 = @{ teamsSettings = @(); sharePointSettings = @() } }
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given)
        @($result['errors'] | Where-Object { $_['workload'] -eq 'Teams' -and $_['message'] -match 'Bad value' }).Count | Should -BeGreaterThan 0
        @($result['settingGaps'] | Where-Object { $_['setting'] -eq 'SharingCapability' }).Count | Should -Be 1
    }

    It 'stops a rule that reports on another workload than the one it runs for' {
        InModuleScope TenantConverge {
            $script:TcRuleRun = @{ Workload = 'Teams'; Findings = [System.Collections.Generic.List[object]]::new(); Tenants = @{}; Source = $null }
            try { { Add-TcFinding 'ENT-RISK' 'S1' } | Should -Throw '*Entra ID*' }
            finally { $script:TcRuleRun = $null }
        }
    }

    It 'refuses a snapshot with no tenants' {
        { Invoke-TcRuleSet -Snapshot ([ordered]@{ schemaVersion = 1 }) } | Should -Throw '*tenants*'
    }
}

Describe 'A finding' {
    BeforeAll {
        $script:Given = @{ S1 = @{ users = @(@{ UPN = 'a@alpine.example'; Type = 'Member'; Enabled = $true; 'Days inactive' = 200; 'Days since creation' = 400 }) } }
        $script:Finding = (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $script:Given))['findings'] | Where-Object { $_['id'] -eq 'ENT-INACTIVE' }
    }

    It 'takes its texts from the catalog and fills them in' {
        $script:Finding['title'] | Should -Be '1 active member account(s) with no sign-in for 90 days or more'
        $script:Finding['finding'] | Should -BeLike '*Alpine*'
        $script:Finding['why'] | Should -Not -BeNullOrEmpty
        $script:Finding['owner'] | Should -Be 'Customer'
        $script:Finding['moment'] | Should -Be 'Now'
        $script:Finding['effort'] | Should -Be 'Medium'
        $script:Finding['question'] | Should -Match '\?$'
    }

    It 'names the tenant and the role' {
        $script:Finding['role'] | Should -Be 'S1'
        $script:Finding['code'] | Should -Be 'S1'
        $script:Finding['tenant'] | Should -Be 'Alpine'
        $script:Finding['workload'] | Should -Be 'Entra ID'
    }

    It 'lists the elements, without blanks, and counts them all' {
        $rows = @(1..305 | ForEach-Object { @{ UPN = "u$_"; Enabled = $false; 'License count' = 1; Licenses = 'A' } })
        $finding = (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given @{ S1 = @{ users = $rows } }))['findings'] | Where-Object { $_['id'] -eq 'ENT-DISABLED-LICENSED' }
        @($finding['items']).Count | Should -Be 300
        $finding['itemCount'] | Should -Be 305
    }
}

Describe 'Rule <Id> on <On>, <Severity>, case <_>' -ForEach $script:RuleCases {
    It 'fires with the expected severity and elements' {
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $Given) -HomeCountry @()
        @($result['errors']).Count | Should -Be 0 -Because (@($result['errors']) | ConvertTo-Json -Depth 3)
        $finding = @($result['findings'] | Where-Object { $_['id'] -eq $Id -and $_['code'] -eq $On })
        $finding.Count | Should -Be 1
        $finding[0]['severity'] | Should -Be $Severity
        $finding[0]['itemCount'] | Should -Be $Items
        if ($Category) { $finding[0]['category'] | Should -Be $Category }
        "$($finding[0]['title']) $($finding[0]['finding']) $($finding[0]['action'])" | Should -Not -Match '[{}]'
    }
}

Describe 'Settings that change a rule' {
    It 'honors a threshold' {
        $given = @{ S1 = @{ users = @(@{ UPN = 'a'; Type = 'Member'; Enabled = $true; 'Days inactive' = 100; 'Days since creation' = 400 }) } }
        Get-TcFindingId (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given)) | Should -Contain 'ENT-INACTIVE'
        (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given) -Threshold @{ inactiveDays = 200 })['findings'] | Where-Object { $_['id'] -eq 'ENT-INACTIVE' } | Should -BeNullOrEmpty
    }

    It 'refuses an unknown threshold' {
        { Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot) -Threshold @{ unknown = 1 } } | Should -Throw '*unknown*'
    }

    It 'takes the home countries from the tenant, or from -HomeCountry' {
        $given = @{ S1 = @{ organizationSettings = @(@{ Setting = 'Country'; Value = 'CA' }); signInSummary = @(@{ Dimension = 'Country'; Value = 'US'; 'Sign-ins' = 3 }) } }
        Get-TcFindingId (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given)) | Should -Contain 'ENT-COUNTRIES'
        (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given) -HomeCountry 'CA', 'US')['findings'] | Where-Object { $_['id'] -eq 'ENT-COUNTRIES' } | Should -BeNullOrEmpty
    }

    It 'sees a vendor account only through its guest form' {
        $given = @{ S1 = @{ adminRoles = @(@{ Role = 'Global Administrator'; Assignment = 'Active'; Principal = 'admin@vendor.example'; 'Principal type' = 'user' }, @{ Role = 'Global Administrator'; Assignment = 'Active'; Principal = 'a@a.example'; 'Principal type' = 'user' }) } }
        (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given))['findings'] | Where-Object { $_['id'] -eq 'ENT-ADMINS' } | Should -BeNullOrEmpty
    }

    It 'names no product of a phone provider in the routing domain test' {
        $given = @{ Target = @{ domains = @(@{ Domain = 'teams-voice.summit.example' }, @{ Domain = 'plain.example' }) } }
        ((Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given))['findings'] | Where-Object { $_['id'] -eq 'TEL-ROUTING-TARGET' })['itemCount'] | Should -Be 1
    }
}

Describe 'Measures' {
    It 'gives one line per indicator, with each tenant, the sources total and the target after consolidation' {
        $given = @{ Target = @{ users = @(@{ Type = 'Member'; Enabled = $true }) }; S1 = @{ users = @(@{ Type = 'Member'; Enabled = $true }, @{ Type = 'Member'; Enabled = $false }) } }
        $measures = @((Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given))['measures'])
        $measures.Count | Should -Be 42
        $line = $measures | Where-Object { $_['label'] -eq 'Active member accounts' }
        $line['values']['Target'] | Should -Be 1
        $line['values']['S1'] | Should -Be 1
        $line['sources'] | Should -Be 1
        $line['after'] | Should -Be 2
        $line['additive'] | Should -BeTrue
    }

    It 'keeps an empty table of a partial collector apart from a zero' {
        $producer = (InModuleScope TenantConverge { Get-TcTableDictionary })['groups']['collectors'][0]
        $coverage = @(New-TcCoverageLine -Role 'S1' -Workload 'Entra ID' -Status 'Partial' -Id $producer)
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given @{ S1 = @{ groups = @() } } -Coverage $coverage)
        ($result['measures'] | Where-Object { $_['label'] -eq 'Groups' })['values']['S1'] | Should -BeNullOrEmpty
    }

    It 'keeps a table that was not collected apart from a zero' {
        $given = @{ Target = @{ teams = @() } }
        $line = (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given))['measures'] | Where-Object { $_['label'] -eq 'Teams' }
        $line['values']['Target'] | Should -Be 0
        $line['values']['S1'] | Should -BeNullOrEmpty
        $line['sources'] | Should -BeNullOrEmpty
        $line['after'] | Should -BeNullOrEmpty
    }

    It 'names the sources a total leaves out' {
        $given = @{ Target = @{ teams = @(@{ Name = 'a' }) }; S1 = @{ teams = @(@{ Name = 'b' }) } }
        $line = (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given -Sources 'S1', 'S2'))['measures'] | Where-Object { $_['label'] -eq 'Teams' }
        $line['sources'] | Should -Be 1
        $line['after'] | Should -Be 2
        @($line['unreadSources']) | Should -Be @('S2')
    }

    It 'leaves out no source when each one was read' {
        $given = @{ S1 = @{ teams = @() }; S2 = @{ teams = @(@{ Name = 'b' }) } }
        $line = (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given -Sources 'S1', 'S2'))['measures'] | Where-Object { $_['label'] -eq 'Teams' }
        $line.Contains('unreadSources') | Should -BeTrue
        @($line['unreadSources']).Count | Should -Be 0
    }

    It 'does not add what cannot add up' {
        $given = @{ Target = @{ users = @(@{ Type = 'Guest' }) }; S1 = @{ users = @(@{ Type = 'Guest' }) } }
        $line = (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given))['measures'] | Where-Object { $_['label'] -eq 'Guest accounts' }
        $line['additive'] | Should -BeFalse
        $line['sources'] | Should -BeNullOrEmpty
    }
}

Describe 'Setting gaps' {
    BeforeAll {
        $script:Settings = {
            param($SharingTarget, $SharingSource, $OtherTarget = 'a', $OtherSource = 'a')
            @{
                Target = @{ sharePointSettings = @(@{ Setting = 'SharingCapability'; Value = $SharingTarget }, @{ Setting = 'SomeOtherFlag'; Value = $OtherTarget }, @{ Setting = 'DisplayName'; Value = 'x' }) }
                S1     = @{ sharePointSettings = @(@{ Setting = 'SharingCapability'; Value = $SharingSource }, @{ Setting = 'SomeOtherFlag'; Value = $OtherSource }, @{ Setting = 'DisplayName'; Value = 'y' }) }
            }
        }
    }

    It 'lists a setting that differs and marks it important when it matters' {
        $gaps = @((Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given (& $script:Settings 'a' 'b' 'c' 'd')))['settingGaps'])
        $gaps.Count | Should -Be 2
        ($gaps | Where-Object { $_['setting'] -eq 'SharingCapability' })['important'] | Should -BeTrue
        ($gaps | Where-Object { $_['setting'] -eq 'SomeOtherFlag' })['important'] | Should -BeFalse
    }

    It 'ignores identifiers and names, and settings that match' {
        @((Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given (& $script:Settings 'a' 'a')))['settingGaps']).Count | Should -Be 0
    }

    It 'turns important gaps into CMP-SETTINGS, for the source that differs' {
        $finding = (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given (& $script:Settings 'a' 'b')))['findings'] | Where-Object { $_['id'] -eq 'CMP-SETTINGS' }
        $finding['code'] | Should -Be 'S1'
        $finding['role'] | Should -Be 'Both'
        $finding['itemCount'] | Should -Be 1
    }

    It 'reads the label of a setting the same way the collector writes it' {
        $given = @{
            Target = @{ teamsSettings = @(@{ Setting = 'External access.AllowPublicUsers'; Value = $true }, @{ Setting = 'External access.AllowFederatedUsers'; Value = $true }, @{ Setting = 'ACS federation.Enabled'; Value = $true }, @{ Setting = 'Guests - meetings.AllowIPVideo'; Value = $true })
                securitySettings = @(@{ Setting = 'Email-based self-service sign-up'; Value = $true }, @{ Setting = 'Method Fido2'; Value = 'enabled' }, @{ Setting = 'DefaultAuthenticationMethod'; Value = 'x' }) }
            S1 = @{ teamsSettings = @(@{ Setting = 'External access.AllowPublicUsers'; Value = $false }, @{ Setting = 'External access.AllowFederatedUsers'; Value = $false }, @{ Setting = 'ACS federation.Enabled'; Value = $false }, @{ Setting = 'Guests - meetings.AllowIPVideo'; Value = $false })
                securitySettings = @(@{ Setting = 'Email-based self-service sign-up'; Value = $false }, @{ Setting = 'Method Fido2'; Value = 'disabled' }, @{ Setting = 'DefaultAuthenticationMethod'; Value = 'y' }) }
        }
        $gaps = @((Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given))['settingGaps'])
        $important = @($gaps | Where-Object { $_['important'] } | ForEach-Object { $_['setting'] })
        $gaps.Count | Should -Be 7
        $important | Should -Contain 'External access.AllowFederatedUsers'
        $important | Should -Contain 'Guests - meetings.AllowIPVideo'
        $important | Should -Contain 'Method Fido2'
        $important | Should -Not -Contain 'External access.AllowPublicUsers'
        $important | Should -Not -Contain 'ACS federation.Enabled'
        $important | Should -Not -Contain 'Email-based self-service sign-up'
        $important | Should -Not -Contain 'DefaultAuthenticationMethod'
    }
}
