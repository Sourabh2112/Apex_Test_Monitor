public with sharing class ApexTestCoverageMonitorController {
    private static final Integer MAX_ROWS = 20;
    private static final String TOOLING_NAMED_CREDENTIAL = 'Apex_Tooling_API';
    @TestVisible private static Boolean skipToolingCalloutInTests = true;

    public class InputRow {
        @AuraEnabled public String apexClassName;
        @AuraEnabled public String testClassName;
    }

    public class StartResponse {
        @AuraEnabled public Id requestId;
        @AuraEnabled public Id orchestrationJobId;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
    }

    public class MonitorStatus {
        @AuraEnabled public Id requestId;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
        @AuraEnabled public String testRunId;
        @AuraEnabled public String testRunStatus;
        @AuraEnabled public String orchestrationStatus;
        @AuraEnabled public Integer jobItemsProcessed;
        @AuraEnabled public Integer totalJobItems;
        @AuraEnabled public Integer numberOfErrors;
        @AuraEnabled public List<ResultRow> rows;
    }

    public class ResultRow {
        @AuraEnabled public String apexClassName;
        @AuraEnabled public String testClassName;
        @AuraEnabled public Decimal apiVersion;
        @AuraEnabled public Decimal codeCoveragePercent;
        @AuraEnabled public Integer linesCovered;
        @AuraEnabled public Integer linesUncovered;
        @AuraEnabled public Integer charactersBeforeIndentation;
        @AuraEnabled public Integer charactersAfterIndentation;
        @AuraEnabled public Integer potentialSavings;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
    }

    @AuraEnabled
    public static StartResponse startTestRun(String rowsJson) {
        List<InputRow> rows = parseRows(rowsJson);
        validateRows(rows);

        Apex_Test_Monitor_Request__c request = new Apex_Test_Monitor_Request__c(
            InputPayload__c = JSON.serialize(rows),
            Status__c = 'Queued',
            Message__c = 'Queued test execution request.'
        );
        insert request;

        Id queueableJobId = System.enqueueJob(new ApexTestCoverageMonitorQueueable(request.Id));
        request.OrchestrationJobId__c = String.valueOf(queueableJobId);
        update request;

        StartResponse response = new StartResponse();
        response.requestId = request.Id;
        response.orchestrationJobId = queueableJobId;
        response.status = request.Status__c;
        response.message = request.Message__c;
        return response;
    }

    @AuraEnabled
    public static MonitorStatus getStatus(Id requestId) {
        if (requestId == null) {
            throw new AuraHandledException('Request id is required.');
        }

        Apex_Test_Monitor_Request__c request = [
            SELECT Id, InputPayload__c, Status__c, Message__c, TestRunId__c, OrchestrationJobId__c, TestQueueItemIds__c
            FROM Apex_Test_Monitor_Request__c
            WHERE Id = :requestId
            LIMIT 1
        ];

        Boolean requestNeedsUpdate = false;
        if (String.isBlank(request.TestRunId__c)) {
            Id resolvedTestRunId = resolveTestRunId(request);
            if (resolvedTestRunId != null) {
                request.TestRunId__c = String.valueOf(resolvedTestRunId);
                request.Message__c = 'Submitted test class(es). Test run job assigned.';
                requestNeedsUpdate = true;
            }
        }

        List<InputRow> inputRows = parseRows(request.InputPayload__c);
        Set<String> apexNames = new Set<String>();
        for (InputRow row : inputRows) {
            apexNames.add(row.apexClassName);
        }

        Map<String, ApexClass> classesByName = new Map<String, ApexClass>();
        for (ApexClass cls : [
            SELECT Id, Name, ApiVersion, Body
            FROM ApexClass
            WHERE Name IN :apexNames
        ]) {
            classesByName.put(cls.Name, cls);
        }

        MonitorStatus status = new MonitorStatus();
        status.requestId = request.Id;
        status.status = request.Status__c;
        status.message = request.Message__c;
        status.testRunId = request.TestRunId__c;
        applyAsyncJobStatus(status, request);

        Map<Id, CoverageSummary> coverageByClassId = new Map<Id, CoverageSummary>();
        String toolingMessage;
        if (!classesByName.isEmpty() && (status.testRunStatus == 'Completed' || (Test.isRunningTest() && !skipToolingCalloutInTests))) {
            try {
                coverageByClassId = queryCoverage(new Map<Id, ApexClass>(classesByName.values()).keySet());
            } catch (Exception ex) {
                toolingMessage = formatToolingError(ex.getMessage());
            }
        } else if (!classesByName.isEmpty()) {
            toolingMessage = 'Coverage will be checked after the Apex test run completes.';
        }

        status.message = combineMessages(request.Message__c, toolingMessage);
        status.rows = buildResultRows(inputRows, classesByName, coverageByClassId, toolingMessage);
        if (requestNeedsUpdate) {
            update request;
        }
        return status;
    }

    public static List<InputRow> parseRows(String rowsJson) {
        if (String.isBlank(rowsJson)) {
            return new List<InputRow>();
        }
        try {
            List<InputRow> rows = (List<InputRow>) JSON.deserialize(rowsJson, List<InputRow>.class);
            return rows == null ? new List<InputRow>() : rows;
        } catch (Exception ex) {
            throw new AuraHandledException('Enter rows in the expected Apex/Test class format.');
        }
    }

    public static void validateRows(List<InputRow> rows) {
        if (rows.isEmpty()) {
            throw new AuraHandledException('Add at least one Apex class and test class pair.');
        }
        if (rows.size() > MAX_ROWS) {
            throw new AuraHandledException('Submit ' + MAX_ROWS + ' or fewer rows at a time.');
        }

        Set<String> uniquePairs = new Set<String>();
        for (InputRow row : rows) {
            row.apexClassName = normalizeName(row.apexClassName);
            row.testClassName = normalizeName(row.testClassName);
            if (String.isBlank(row.apexClassName) || String.isBlank(row.testClassName)) {
                throw new AuraHandledException('Every row must include both class names.');
            }
            String key = row.apexClassName.toLowerCase() + '|' + row.testClassName.toLowerCase();
            if (uniquePairs.contains(key)) {
                throw new AuraHandledException('Remove duplicate class/test pairs before submitting.');
            }
            uniquePairs.add(key);
        }
    }

    private static String normalizeName(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    private static List<ResultRow> buildResultRows(
        List<InputRow> inputRows,
        Map<String, ApexClass> classesByName,
        Map<Id, CoverageSummary> coverageByClassId,
        String toolingMessage
    ) {
        List<ResultRow> results = new List<ResultRow>();
        for (InputRow input : inputRows) {
            ResultRow row = new ResultRow();
            row.apexClassName = input.apexClassName;
            row.testClassName = input.testClassName;

            ApexClass cls = classesByName.get(input.apexClassName);
            if (cls == null) {
                row.status = 'Missing Apex class';
                row.message = 'No Apex class found with this name.';
                results.add(row);
                continue;
            }

            row.apiVersion = cls.ApiVersion;
            row.charactersBeforeIndentation = cls.Body == null ? 0 : cls.Body.length();
            row.charactersAfterIndentation = countAfterTabIndentation(cls.Body);
            row.potentialSavings = Math.max(0, row.charactersBeforeIndentation - row.charactersAfterIndentation);

            CoverageSummary coverage = coverageByClassId.get(cls.Id);
            if (coverage == null) {
                row.status = toolingMessage == null || toolingMessage.startsWith('Coverage will be checked')
                    ? 'Coverage pending'
                    : 'Coverage unavailable';
                row.message = toolingMessage == null ? 'Coverage data appears after the test run updates aggregates.' : toolingMessage;
            } else {
                row.linesCovered = coverage.covered;
                row.linesUncovered = coverage.uncovered;
                Integer totalLines = coverage.covered + coverage.uncovered;
                row.codeCoveragePercent = totalLines == 0
                    ? 100
                    : ((Decimal.valueOf(coverage.covered) / Decimal.valueOf(totalLines)) * 100).setScale(2);
                row.status = 'Coverage available';
            }
            results.add(row);
        }
        return results;
    }

    private static Integer countAfterTabIndentation(String body) {
        if (String.isBlank(body)) {
            return 0;
        }

        List<String> rawLines = body
            .replace('\r\n', '\n')
            .replace('\r', '\n')
            .split('\n');

        List<String> cleanedLines = new List<String>();

        // ✅ Step 1: Normalize blank lines (Prettier behavior)
        Boolean previousWasBlank = false;

        for (String line : rawLines) {
            String trimmed = line == null ? '' : line.trim();

            if (trimmed == '') {
                if (!previousWasBlank) {
                    cleanedLines.add(''); // keep single blank line
                    previousWasBlank = true;
                }
            } else {
                cleanedLines.add(trimmed);
                previousWasBlank = false;
            }
        }

        Integer indent = 0;
        Integer charCount = 0;

        // ✅ Step 2: Apply indentation + count
        for (Integer i = 0; i < cleanedLines.size(); i++) {
            String line = cleanedLines[i];

            if (line == '') {
                // ✅ one newline only
                charCount += 1;
                continue;
            }

            // adjust indent before line
            if (line.startsWith('}')) {
                indent = Math.max(0, indent - 1);
            }

            // ✅ indentation as tabs (1 tab = 1 char)
            charCount += indent;

            // ✅ actual content
            charCount += line.length();

            // ✅ newline
            if (i < cleanedLines.size() - 1) {
                charCount += 1;
            }

            // adjust indent after
            if (line.endsWith('{')) {
                indent++;
            }
        }

        return charCount;
    }

    private static void applyAsyncJobStatus(MonitorStatus status, Apex_Test_Monitor_Request__c request) {
        if (String.isNotBlank(request.OrchestrationJobId__c)) {
            List<AsyncApexJob> queueableJobs = [
                SELECT Status, NumberOfErrors, ExtendedStatus
                FROM AsyncApexJob
                WHERE Id = :request.OrchestrationJobId__c
                LIMIT 1
            ];
            if (!queueableJobs.isEmpty()) {
                status.orchestrationStatus = queueableJobs[0].Status;
            }
        }

        if (String.isBlank(request.TestRunId__c)) {
            status.testRunStatus = 'Pending';
            return;
        }

        List<AsyncApexJob> testJobs = [
            SELECT Status, JobItemsProcessed, TotalJobItems, NumberOfErrors, ExtendedStatus
            FROM AsyncApexJob
            WHERE Id = :request.TestRunId__c
            LIMIT 1
        ];
        if (testJobs.isEmpty()) {
            return;
        }

        AsyncApexJob job = testJobs[0];
        status.testRunStatus = job.Status;
        status.jobItemsProcessed = job.JobItemsProcessed;
        status.totalJobItems = job.TotalJobItems;
        status.numberOfErrors = job.NumberOfErrors;
        if (job.Status == 'Completed' || job.Status == 'Failed' || job.Status == 'Aborted') {
            status.status = job.Status;
        } else {
            status.status = 'Running';
        }
    }

    private static Id resolveTestRunId(Apex_Test_Monitor_Request__c request) {
        Set<Id> queueItemIds = parseIdSet(request.TestQueueItemIds__c);
        if (queueItemIds.isEmpty()) {
            return null;
        }

        Id parentJobId;
        for (ApexTestQueueItem queueItem : [
            SELECT ParentJobId
            FROM ApexTestQueueItem
            WHERE Id IN :queueItemIds
        ]) {
            if (queueItem.ParentJobId != null) {
                parentJobId = queueItem.ParentJobId;
                break;
            }
        }

        return parentJobId;
    }

    private static Set<Id> parseIdSet(String csvIds) {
        Set<Id> ids = new Set<Id>();
        if (String.isBlank(csvIds)) {
            return ids;
        }
        for (String rawId : csvIds.split(',')) {
            String trimmed = rawId == null ? null : rawId.trim();
            if (String.isNotBlank(trimmed)) {
                ids.add((Id) trimmed);
            }
        }
        return ids;
    }

    private static Map<Id, CoverageSummary> queryCoverage(Set<Id> classIds) {
        if (Test.isRunningTest() && skipToolingCalloutInTests) {
            return new Map<Id, CoverageSummary>();
        }

        List<String> quotedClassIds = new List<String>();
        for (Id classId : classIds) {
            quotedClassIds.add('\'' + String.escapeSingleQuotes(String.valueOf(classId)) + '\'');
        }

        String soql = 'SELECT ApexClassOrTriggerId, NumLinesCovered, NumLinesUncovered ' +
            'FROM ApexCodeCoverageAggregate ' +
            'WHERE ApexClassOrTriggerId IN (' + String.join(quotedClassIds, ',') + ')';

        HttpRequest request = new HttpRequest();
        request.setMethod('GET');
        request.setHeader('Content-Type', 'application/json');
        request.setEndpoint('callout:' + TOOLING_NAMED_CREDENTIAL + '/services/data/v61.0/tooling/query/?q=' + EncodingUtil.urlEncode(soql, 'UTF-8'));

        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() < 200 || response.getStatusCode() > 299) {
            throw new CalloutException('Tooling API returned ' + response.getStatusCode() + ': ' + response.getBody());
        }

        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
        List<Object> records = (List<Object>) payload.get('records');
        Map<Id, CoverageSummary> coverageByClassId = new Map<Id, CoverageSummary>();
        if (records == null) {
            return coverageByClassId;
        }

        for (Object recordValue : records) {
            Map<String, Object> record = (Map<String, Object>) recordValue;
            Id classId = String.valueOf(record.get('ApexClassOrTriggerId'));
            CoverageSummary summary = new CoverageSummary();
            summary.covered = Integer.valueOf(String.valueOf(record.get('NumLinesCovered')));
            summary.uncovered = Integer.valueOf(String.valueOf(record.get('NumLinesUncovered')));
            coverageByClassId.put(classId, summary);
        }
        return coverageByClassId;
    }

    private static String combineMessages(String requestMessage, String toolingMessage) {
        if (String.isBlank(toolingMessage)) {
            return requestMessage;
        }
        return String.isBlank(requestMessage) ? toolingMessage : requestMessage + ' ' + toolingMessage;
    }

    private static String formatToolingError(String message) {
        if (String.isBlank(message)) {
            return 'Coverage unavailable.';
        }
        if (message.contains('INVALID_SESSION_ID') || message.contains('This session is not valid')) {
            return 'Coverage unavailable: configure the Apex_Tooling_API Named Credential. Lightning sessions cannot be reused for Tooling API REST calls.';
        }
        if (message.contains('Apex_Tooling_API')) {
            return 'Coverage unavailable: Named Credential Apex_Tooling_API was not found or is not authorized.';
        }
        return 'Coverage unavailable: ' + message;
    }

    private class CoverageSummary {
        Integer covered = 0;
        Integer uncovered = 0;
    }
}