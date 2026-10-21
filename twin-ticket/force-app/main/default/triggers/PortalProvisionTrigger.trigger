trigger PortalProvisionTrigger on Portal_Provision__e (after insert) {
    PortalProvisioningService.handleEvents(Trigger.new);
}