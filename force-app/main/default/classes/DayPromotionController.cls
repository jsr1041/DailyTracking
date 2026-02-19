public without sharing class DayPromotionController {
    @AuraEnabled
    public static DayPromotionService.Result promote(Id recordId) {
        // recordId here is the Staging_Day__c Id from the record page
        return DayPromotionService.promoteOne(recordId);
    }
}