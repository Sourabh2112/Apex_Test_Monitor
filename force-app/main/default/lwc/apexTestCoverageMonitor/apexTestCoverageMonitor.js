import { LightningElement } from 'lwc';
import startTestRun from '@salesforce/apex/ApexTestCoverageMonitorController.startTestRun';
import getStatus from '@salesforce/apex/ApexTestCoverageMonitorController.getStatus';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const POLL_INTERVAL_MS = 5000;
const TERMINAL_STATUSES = new Set(['Completed', 'Failed', 'Aborted']);

export default class ApexTestCoverageMonitor extends LightningElement {
    rows = [this.newRow()];
    resultRows = [];
    status;
    requestId;
    bulkText = '';
    isBusy = false;
    errorMessage = '';
    pollHandle;
    nextKey = 1;

    columns = [
        { label: 'Apex Class Name', fieldName: 'apexClassName', wrapText: true },
        { label: 'Test Class Name', fieldName: 'testClassName', wrapText: true },
        { label: 'API Version', fieldName: 'apiVersion', type: 'number', initialWidth: 120 },
        { label: 'Coverage %', fieldName: 'codeCoveragePercent', type: 'number', initialWidth: 120 },
        { label: 'Covered', fieldName: 'linesCovered', type: 'number', initialWidth: 100 },
        { label: 'Uncovered', fieldName: 'linesUncovered', type: 'number', initialWidth: 115 },
        { label: 'Chars Before', fieldName: 'charactersBeforeIndentation', type: 'number', initialWidth: 130 },
        { label: 'Chars After', fieldName: 'charactersAfterIndentation', type: 'number', initialWidth: 120 },
        { label: 'Savings', fieldName: 'potentialSavings', type: 'number', initialWidth: 100 },
        { label: 'Status', fieldName: 'status', wrapText: true },
        { label: 'Message', fieldName: 'message', wrapText: true }
    ];

    disconnectedCallback() {
        this.stopPolling();
    }

    get isRunDisabled() {
        return this.isBusy || !this.rows.some((row) => row.apexClassName?.trim() && row.testClassName?.trim());
    }

    get isRemoveDisabled() {
        return this.isBusy || this.rows.length === 1;
    }

    get hasResults() {
        return this.resultRows.length > 0;
    }

     // NEW
    get isDownloadDisabled() {
        return this.isBusy || !this.hasResults;
    }

    get progressLabel() {
        if (!this.status) return '';
        const processed = this.status.jobItemsProcessed ?? 0;
        const total = this.status.totalJobItems ?? 0;
        return total ? `${processed} / ${total}` : 'Pending';
    }

    newRow(values = {}) {
        const key = String(this.nextKey ?? 0);
        this.nextKey = (this.nextKey ?? 0) + 1;
        return {
            key,
            apexClassName: values.apexClassName ?? '',
            testClassName: values.testClassName ?? ''
        };
    }

    handleAddRow() {
        this.rows = [...this.rows, this.newRow()];
    }

    handleRemoveRow(event) {
        const key = event.currentTarget.dataset.key;
        this.rows = this.rows.filter((row) => row.key !== key);
    }

    handleRowChange(event) {
        const key = event.currentTarget.dataset.key;
        const field = event.currentTarget.dataset.field;
        const value = event.target.value;
        this.rows = this.rows.map((row) => (row.key === key ? { ...row, [field]: value } : row));
    }

    handleBulkTextChange(event) {
        this.bulkText = event.target.value;
    }

    handleApplyBulkText() {
        const parsedRows = this.bulkText
            .split(/\r?\n/)
            .map((line) => line.trim())
            .filter(Boolean)
            .map((line) => {
                const [apexClassName, testClassName] = line.split(/[,|\t]/).map((part) => part?.trim());
                return this.newRow({ apexClassName, testClassName });
            })
            .filter((row) => row.apexClassName || row.testClassName);

        if (!parsedRows.length) {
            this.showToast('No rows found', 'Paste valid class pairs.', 'warning');
            return;
        }
        this.rows = parsedRows;
    }

    async handleRunTests() {
        this.errorMessage = '';
        this.status = undefined;
        this.resultRows = [];
        this.stopPolling();

        const payload = this.rows
            .map(({ apexClassName, testClassName }) => ({
                apexClassName: apexClassName?.trim(),
                testClassName: testClassName?.trim()
            }))
            .filter((row) => row.apexClassName || row.testClassName);

        this.isBusy = true;
        try {
            const response = await startTestRun({ rowsJson: JSON.stringify(payload) });
            this.requestId = response.requestId;
            this.status = response;
            this.showToast('Test run queued', response.message, 'success');
            await this.refreshStatus();
            this.startPolling();
        } catch (error) {
            this.handleError(error);
            this.isBusy = false;
        }
    }

    startPolling() {
        this.pollHandle = window.setInterval(() => this.refreshStatus(), POLL_INTERVAL_MS);
    }

    stopPolling() {
        if (this.pollHandle) {
            window.clearInterval(this.pollHandle);
            this.pollHandle = undefined;
        }
    }

    async refreshStatus() {
        if (!this.requestId) return;

        try {
            const response = await getStatus({ requestId: this.requestId });
            this.status = response;

            this.resultRows = (response.rows ?? []).map((row, index) => ({
                rowKey: `${row.apexClassName}-${row.testClassName}-${index}`,
                ...row
            }));

            const finalStatus = response.testRunStatus || response.status;

            if (TERMINAL_STATUSES.has(finalStatus)) {
                this.stopPolling();
                this.isBusy = false;
            }
        } catch (error) {
            this.handleError(error);
            this.stopPolling();
            this.isBusy = false;
        }
    }

     // NEW FUNCTION
    handleDownloadCSV() {
        try {
            console.log('Download started ✅');

            if (!this.resultRows || this.resultRows.length === 0) {
                this.showToast('No Data', 'Nothing to download.', 'warning');
                return;
            }

            const headers = [
                'Apex Class',
                'Test Class',
                'API Version',
                'Coverage %',
                'Lines Covered',
                'Lines Uncovered',
                'Chars Before',
                'Chars After',
                'Savings',
                'Status',
                'Message'
            ];

            let csvContent = '';

            // ✅ Add headers
            csvContent += headers.join(',') + '\n';

            // ✅ Add rows
            this.resultRows.forEach(row => {
                const values = [
                    row.apexClassName || '',
                    row.testClassName || '',
                    row.apiVersion || '',
                    row.codeCoveragePercent || '',
                    row.linesCovered || '',
                    row.linesUncovered || '',
                    row.charactersBeforeIndentation || '',
                    row.charactersAfterIndentation || '',
                    row.potentialSavings || '',
                    row.status || '',
                    row.message || ''
                ];

                const escaped = values.map(v => {
                    const val = String(v).replace(/"/g, '""');
                    return `"${val}"`;
                });

                csvContent += escaped.join(',') + '\n';
            });

            console.log('CSV built ✅');

            // CRITICAL FIX: Use data URI instead of Blob
            const encodedUri = 'data:text/csv;charset=utf-8,' + encodeURIComponent(csvContent);

            const link = document.createElement('a');
            link.setAttribute('href', encodedUri);
            link.setAttribute('download', `Apex_Test_Coverage_${Date.now()}.csv`);

            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);

            console.log('Download triggered ✅');

        } catch (error) {
            console.error('Download failed ❌', error);
            this.showToast('Error', 'Download failed. Check console.', 'error');
        }
    }

    // NEW HELPER
    downloadFile(csvContent) {
        const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
        const url = URL.createObjectURL(blob);

        const link = document.createElement('a');
        link.href = url;
        link.download = `Apex_Test_Coverage_${Date.now()}.csv`;

        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
    }

    handleError(error) {
        this.errorMessage = error?.body?.message || error?.message || 'Unexpected error.';
        this.showToast('Error', this.errorMessage, 'error');
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}