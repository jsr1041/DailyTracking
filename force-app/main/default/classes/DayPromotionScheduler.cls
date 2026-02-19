global without sharing class DayPromotionScheduler implements Schedulable {
    // Tune this if you expect large volumes
    public static final Integer BATCH_SIZE = 200;

    global void execute(SchedulableContext sc) {
        // Only pick records that should be processed:
        List<Staging_Day__c> candidates = [
            SELECT Id
            FROM Staging_Day__c
            WHERE Status__c = 'Ready to Process'
            ORDER BY CreatedDate ASC
            LIMIT :BATCH_SIZE
        ];

        if (candidates.isEmpty()) return;

        List<Id> ids = new List<Id>();
        for (Staging_Day__c s : candidates) ids.add(s.Id);

        // Run the promotion logic
        // (DayPromotionService already sets Status__c / Processing_Error__c / Day__c / Month__c)
        DayPromotionService.promoteMany(ids);
    }
}