@IsTest
private class ApexTestCoverageMonitorControllerTest {
    @IsTest
    static void startTestRunQueuesRequestAndUpdatesStatus() {
        String payload = JSON.serialize(new List<ApexTestCoverageMonitorController.InputRow>{
            input('ApexTestCoverageMonitorController', 'ApexTestCoverageMonitorControllerTest')
        });

        Test.startTest();
        ApexTestCoverageMonitorController.StartResponse response =
            ApexTestCoverageMonitorController.startTestRun(payload);
        Test.stopTest();

        System.assertNotEquals(null, response.requestId, 'The controller should create a monitor request.');
        Apex_Test_Monitor_Request__c request = [
            SELECT Status__c, TestRunId__c, OrchestrationJobId__c, Message__c
            FROM Apex_Test_Monitor_Request__c
            WHERE Id = :response.requestId
        ];
        System.assertEquals('Running', request.Status__c);
        System.assertEquals('707000000000000AAA', request.TestRunId__c);
        System.assertNotEquals(null, request.OrchestrationJobId__c);
        System.assert(request.Message__c.contains('Submitted'), 'Queueable should mark submitted test classes.');
    }

    @IsTest
    static void getStatusReturnsRowsForRequest() {
        ApexClass controllerClass = [
            SELECT Id
            FROM ApexClass
            WHERE Name = 'ApexTestCoverageMonitorController'
            LIMIT 1
        ];
        ApexTestCoverageMonitorController.skipToolingCalloutInTests = false;
        Test.setMock(HttpCalloutMock.class, new CoverageMock(controllerClass.Id));

        Apex_Test_Monitor_Request__c request = new Apex_Test_Monitor_Request__c(
            InputPayload__c = JSON.serialize(new List<ApexTestCoverageMonitorController.InputRow>{
                input('ApexTestCoverageMonitorController', 'ApexTestCoverageMonitorControllerTest')
            }),
            Status__c = 'Running',
            Message__c = 'Submitted.',
            TestRunId__c = '707000000000000AAA'
        );
        insert request;

        Test.startTest();
        ApexTestCoverageMonitorController.MonitorStatus status =
            ApexTestCoverageMonitorController.getStatus(request.Id);
        Test.stopTest();

        System.assertEquals(request.Id, status.requestId);
        System.assertEquals(1, status.rows.size());
        System.assertEquals('ApexTestCoverageMonitorController', status.rows[0].apexClassName);
        System.assertNotEquals(null, status.rows[0].apiVersion);
        System.assertEquals(Decimal.valueOf(80), status.rows[0].codeCoveragePercent);
        System.assert(status.rows[0].charactersBeforeIndentation > 0);
    }

    @IsTest
    static void getStatusFormatsToolingSessionErrors() {
        ApexTestCoverageMonitorController.skipToolingCalloutInTests = false;
        Test.setMock(HttpCalloutMock.class, new ToolingErrorMock(401, '[{"message":"This session is not valid for use with the REST API","errorCode":"INVALID_SESSION_ID"}]'));

        Apex_Test_Monitor_Request__c request = new Apex_Test_Monitor_Request__c(
            InputPayload__c = JSON.serialize(new List<ApexTestCoverageMonitorController.InputRow>{
                input('ApexTestCoverageMonitorController', 'ApexTestCoverageMonitorControllerTest')
            }),
            Status__c = 'Running',
            Message__c = 'Submitted.',
            TestRunId__c = '707000000000000AAA'
        );
        insert request;

        ApexTestCoverageMonitorController.MonitorStatus status =
            ApexTestCoverageMonitorController.getStatus(request.Id);

        System.assert(status.message.contains('Coverage unavailable'), 'The user-facing error should explain coverage is unavailable.');
        System.assertEquals('Coverage unavailable', status.rows[0].status);
    }

    @IsTest
    static void getStatusHandlesMissingApexClass() {
        Apex_Test_Monitor_Request__c request = new Apex_Test_Monitor_Request__c(
            InputPayload__c = JSON.serialize(new List<ApexTestCoverageMonitorController.InputRow>{
                input('NoSuchApexClassForMonitor', 'ApexTestCoverageMonitorControllerTest')
            }),
            Status__c = 'Queued',
            Message__c = 'Queued.'
        );
        insert request;

        ApexTestCoverageMonitorController.MonitorStatus status =
            ApexTestCoverageMonitorController.getStatus(request.Id);

        System.assertEquals('Missing Apex class', status.rows[0].status);
    }

    @IsTest
    static void queueableFailsWhenTestClassIsMissing() {
        Apex_Test_Monitor_Request__c request = new Apex_Test_Monitor_Request__c(
            InputPayload__c = JSON.serialize(new List<ApexTestCoverageMonitorController.InputRow>{
                input('ApexTestCoverageMonitorController', 'NoSuchTestClassForMonitor')
            }),
            Status__c = 'Queued'
        );
        insert request;

        Test.startTest();
        System.enqueueJob(new ApexTestCoverageMonitorQueueable(request.Id));
        Test.stopTest();

        request = [
            SELECT Status__c, Message__c
            FROM Apex_Test_Monitor_Request__c
            WHERE Id = :request.Id
        ];
        System.assertEquals('Failed', request.Status__c);
        System.assert(request.Message__c.contains('Missing test class'));
    }

    @IsTest
    static void queueableFailsWhenNoRunnableTestsExist() {
        Apex_Test_Monitor_Request__c request = new Apex_Test_Monitor_Request__c(
            InputPayload__c = JSON.serialize(new List<ApexTestCoverageMonitorController.InputRow>()),
            Status__c = 'Queued'
        );
        insert request;

        Test.startTest();
        System.enqueueJob(new ApexTestCoverageMonitorQueueable(request.Id));
        Test.stopTest();

        request = [
            SELECT Status__c, Message__c
            FROM Apex_Test_Monitor_Request__c
            WHERE Id = :request.Id
        ];
        System.assertEquals('Failed', request.Status__c);
        System.assert(request.Message__c.contains('No test classes'));
    }

    @IsTest
    static void validationRejectsDuplicatePairs() {
        List<ApexTestCoverageMonitorController.InputRow> rows =
            new List<ApexTestCoverageMonitorController.InputRow>{
                input('MyClass', 'MyClassTest'),
                input(' myclass ', ' myclasstest ')
            };

        Boolean failed = false;
        try {
            ApexTestCoverageMonitorController.validateRows(rows);
        } catch (AuraHandledException ex) {
            failed = true;
        }
        System.assert(failed, 'Expected duplicate validation to fail.');
    }

    @IsTest
    static void validationRejectsBlankAndTooManyRows() {
        assertValidationFails(new List<ApexTestCoverageMonitorController.InputRow>{
            input('', 'SomeTest')
        });

        List<ApexTestCoverageMonitorController.InputRow> rows = new List<ApexTestCoverageMonitorController.InputRow>();
        for (Integer i = 0; i < 21; i++) {
            rows.add(input('Class' + i, 'Class' + i + 'Test'));
        }
        assertValidationFails(rows);
    }

    @IsTest
    static void parseRowsRejectsMalformedJson() {
        Boolean failed = false;
        try {
            ApexTestCoverageMonitorController.parseRows('{not-json');
        } catch (AuraHandledException ex) {
            failed = true;
        }
        System.assert(failed, 'Expected malformed JSON to fail.');
    }

    private static void assertValidationFails(List<ApexTestCoverageMonitorController.InputRow> rows) {
        Boolean failed = false;
        try {
            ApexTestCoverageMonitorController.validateRows(rows);
        } catch (AuraHandledException ex) {
            failed = true;
        }
        System.assert(failed, 'Expected validation to fail.');
    }

    private static ApexTestCoverageMonitorController.InputRow input(String apexClassName, String testClassName) {
        ApexTestCoverageMonitorController.InputRow row = new ApexTestCoverageMonitorController.InputRow();
        row.apexClassName = apexClassName;
        row.testClassName = testClassName;
        return row;
    }

    private class CoverageMock implements HttpCalloutMock {
        private Id classId;

        CoverageMock(Id classId) {
            this.classId = classId;
        }

        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'application/json');
            response.setBody('{"totalSize":1,"done":true,"records":[{"attributes":{"type":"ApexCodeCoverageAggregate"},"ApexClassOrTriggerId":"' +
                String.valueOf(classId) + '","NumLinesCovered":8,"NumLinesUncovered":2}]}');
            return response;
        }
    }

    private class ToolingErrorMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;

        ToolingErrorMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            response.setBody(body);
            return response;
        }
    }
}
