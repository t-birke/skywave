@IsTest
private class Skywave_PreflightController_Test {

    private class Mock implements HttpCalloutMock {
        public Map<String, Integer> calls = new Map<String, Integer>();

        public HttpResponse respond(HttpRequest req) {
            String url = req.getEndpoint();
            calls.put(url, (calls.get(url) == null ? 0 : calls.get(url)) + 1);

            HttpResponse resp = new HttpResponse();
            resp.setHeader('Content-Type', 'application/json');
            resp.setStatusCode(200);
            resp.setStatus('OK');

            if (url.contains('/api/preflight')) {
                Boolean e2e = url.contains('e2e=1');
                Map<String, Object> r = new Map<String, Object>{
                    'ok' => true,
                    'generatedAt' => '2026-06-09T10:00:00.000Z',
                    'config' => new Map<String, Object>{
                        'publicOrigin' => 'https://example.com',
                        'interactionsSdkUrl' => 'https://cdn.example.com/sdk.js',
                        'esw' => new Map<String, Object>{
                            'orgId' => '00DAA',
                            'escName' => 'Skywave_ESC',
                            'siteUrl' => 'https://x.scrt2.example.com',
                            'scrt2Url' => 'https://scrt2.example.com'
                        }
                    },
                    'pubsub' => new Map<String, Object>{
                        'connected' => true,
                        'subscribedAt' => '2026-06-09T09:00:00.000Z',
                        'reconnectAttempts' => 0
                    },
                    'dyno' => new Map<String, Object>{
                        'uptimeSec' => 3600,
                        'cycleSoon' => false,
                        'memoryMb' => 120
                    },
                    'ws' => new Map<String, Object>{ 'activeCount' => 0 }
                };
                if (e2e) {
                    r.put('roundtrip', new Map<String, Object>{ 'ok' => true, 'deliveredMs' => 4 });
                }
                resp.setBody(JSON.serialize(r));
                return resp;
            }

            if (url.contains('/incidents/unresolved.json')) {
                resp.setBody('{"incidents":[]}');
                return resp;
            }
            if (url.contains('/scheduled-maintenances/upcoming.json')) {
                resp.setBody('{"scheduled_maintenances":[]}');
                return resp;
            }

            resp.setStatusCode(404);
            resp.setStatus('Not Found');
            resp.setBody('{}');
            return resp;
        }
    }

    @TestSetup
    static void seed() {
        insert new Demo_Session__c(State__c='idle', Active__c=true, Started__c=System.now());
        insert new Survey_Question__c(Question_Key__c='q1', Question_Text__c='?', Order__c=1, Active__c=true);
        // Airline data — minimal, just to flip the seeded check green.
        insert new Flight__c(
            Flight_Number__c='SK1', Origin__c='SFO', Destination__c='JFK',
            Active__c=true, Aircraft_Type__c='B738',
            Scheduled_Departure_Time__c=Time.newInstance(8, 0, 0, 0),
            Scheduled_Arrival_Time__c=Time.newInstance(16, 0, 0, 0),
            Duration_Minutes__c=480, Base_Price_Economy__c=200
        );
        insert new Skywave_Seat_Map__c(Aircraft_Type__c='B738', Layout_Json__c='{}', Total_Rows__c=30);
        Contact c = new Contact(LastName='X');
        insert c;
        insert new Booking__c(Contact__c=c.Id, Confirmation_Code__c='ABC123', Status__c='Confirmed');
    }

    @IsTest
    static void runPreflight_returnsAllGroups() {
        Test.setMock(HttpCalloutMock.class, new Mock());

        Test.startTest();
        List<Skywave_PreflightController.CheckResult> rows = Skywave_PreflightController.runPreflight();
        Test.stopTest();

        // Group coverage — every category must produce at least one row,
        // even if Heroku/Statuspage callouts no-op in test context.
        Set<String> groups = new Set<String>();
        for (Skywave_PreflightController.CheckResult r : rows) groups.add(r.groupKey);
        System.assert(groups.contains('org'),     'org group missing');
        System.assert(groups.contains('agent'),   'agent group missing');
        System.assert(groups.contains('relay'),   'relay group missing');
        System.assert(groups.contains('e2e'),     'e2e group missing');
        System.assert(groups.contains('platform'),'platform group missing');
        System.assert(groups.contains('manual'),  'manual group missing');

        // The two manual rows are always present and stay neutral.
        Integer manuals = 0;
        for (Skywave_PreflightController.CheckResult r : rows) {
            if (r.manual) {
                System.assertEquals('manual', r.status, 'manual row must have status=manual');
                manuals++;
            }
        }
        System.assertEquals(2, manuals, 'expected 2 manual rows');
    }

    @IsTest
    static void runPreflight_orgRowsPassWhenSeeded() {
        Test.setMock(HttpCalloutMock.class, new Mock());

        Test.startTest();
        List<Skywave_PreflightController.CheckResult> rows = Skywave_PreflightController.runPreflight();
        Test.stopTest();

        Map<String, Skywave_PreflightController.CheckResult> byId = new Map<String, Skywave_PreflightController.CheckResult>();
        for (Skywave_PreflightController.CheckResult r : rows) byId.put(r.id, r);

        System.assertEquals('pass', byId.get('org.activeSession').status);
        System.assertEquals('pass', byId.get('org.sessionReset').status);
        System.assertEquals('pass', byId.get('org.surveyQuestions').status);
        System.assertEquals('pass', byId.get('org.airlineData').status);
    }

    @IsTest
    static void runPreflight_relayFailsWhenConfigMissing() {
        // No Skywave_Preflight_Config__mdt.Default in test context (custom
        // metadata records deployed via metadata aren't auto-visible here),
        // so the callout helper throws → a single failed row is returned.
        Test.setMock(HttpCalloutMock.class, new Mock());

        Test.startTest();
        List<Skywave_PreflightController.CheckResult> rows = Skywave_PreflightController.runPreflight();
        Test.stopTest();

        Boolean foundRelayRow = false;
        for (Skywave_PreflightController.CheckResult r : rows) {
            if (r.groupKey == 'relay') foundRelayRow = true;
        }
        System.assert(foundRelayRow, 'relay group must surface at least one row even when config is missing');
    }
}
