public with sharing class ApexTestCoverageMonitorQueueable implements Queueable {
    private Id requestId;

    public ApexTestCoverageMonitorQueueable(Id requestId) {
        this.requestId = requestId;
    }

    public void execute(QueueableContext context) {
        Apex_Test_Monitor_Request__c request = [
            SELECT Id, InputPayload__c
            FROM Apex_Test_Monitor_Request__c
            WHERE Id = :requestId
            LIMIT 1
            FOR UPDATE
        ];

        try {
            List<ApexTestCoverageMonitorController.InputRow> rows =
                ApexTestCoverageMonitorController.parseRows(request.InputPayload__c);
            Set<String> testClassNames = new Set<String>();
            for (ApexTestCoverageMonitorController.InputRow row : rows) {
                if (String.isNotBlank(row.testClassName)) {
                    testClassNames.add(row.testClassName.trim());
                }
            }

            Map<String, ApexClass> testClassesByName = new Map<String, ApexClass>();
            for (ApexClass testClass : [
                SELECT Id, Name
                FROM ApexClass
                WHERE Name IN :testClassNames
            ]) {
                testClassesByName.put(testClass.Name, testClass);
            }

            List<String> missingTestClasses = new List<String>();
            List<ApexTestQueueItem> queueItems = new List<ApexTestQueueItem>();
            for (String testClassName : testClassNames) {
                ApexClass testClass = testClassesByName.get(testClassName);
                if (testClass == null) {
                    missingTestClasses.add(testClassName);
                } else {
                    queueItems.add(new ApexTestQueueItem(ApexClassId = testClass.Id));
                }
            }

            if (!missingTestClasses.isEmpty()) {
                failRequest(request, 'Missing test class(es): ' + String.join(missingTestClasses, ', '));
                return;
            }
            if (queueItems.isEmpty()) {
                failRequest(request, 'No test classes were available to run.');
                return;
            }

            TestSubmission submission = submitTestQueueItems(queueItems);

            request.Status__c = 'Running';
            request.TestRunId__c = submission.parentJobId == null ? null : String.valueOf(submission.parentJobId);
            request.TestQueueItemIds__c = String.join(submission.queueItemIds, ',');
            request.Message__c = submission.parentJobId == null
                ? 'Submitted test queue items. Waiting for Salesforce to assign the parent test run job.'
                : 'Submitted ' + queueItems.size() + ' test class(es).';
            update request;
        } catch (Exception ex) {
            failRequest(request, ex.getMessage());
        }
    }

    private static TestSubmission submitTestQueueItems(List<ApexTestQueueItem> queueItems) {
        TestSubmission submission = new TestSubmission();
        if (Test.isRunningTest()) {
            submission.parentJobId = '707000000000000AAA';
            return submission;
        }

        insert queueItems;

        Set<Id> queueItemIds = new Set<Id>();
        for (ApexTestQueueItem queueItem : queueItems) {
            queueItemIds.add(queueItem.Id);
            submission.queueItemIds.add(String.valueOf(queueItem.Id));
        }

        for (ApexTestQueueItem queueItem : [
            SELECT ParentJobId
            FROM ApexTestQueueItem
            WHERE Id IN :queueItemIds
        ]) {
            if (queueItem.ParentJobId != null) {
                submission.parentJobId = queueItem.ParentJobId;
                return submission;
            }
        }
        return submission;
    }

    private static void failRequest(Apex_Test_Monitor_Request__c request, String message) {
        request.Status__c = 'Failed';
        request.Message__c = message;
        update request;
    }

    private class TestSubmission {
        Id parentJobId;
        List<String> queueItemIds = new List<String>();
    }
}
