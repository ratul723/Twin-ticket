/** Writes integration logs in a SEPARATE transaction. The provisioning transaction changes setup objects (User),
 *  and Apex forbids mixing those with ordinary record changes in one transaction. */
public without sharing class PortalLogJob implements Queueable {
    private List<Integration_Log__c> rows;
    public PortalLogJob(List<Integration_Log__c> rows) { this.rows = rows; }

    public void execute(QueueableContext ctx) {
        try {
            insert rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'TT-PORTAL could not write provisioning logs: ' + e.getMessage());
        }
    }
}