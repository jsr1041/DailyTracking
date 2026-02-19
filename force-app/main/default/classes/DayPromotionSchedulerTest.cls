@IsTest
private class DayPromotionSchedulerTest {

        /* Utility: create a valid Date that yields a specific day-of-month */
    private static Date makeDate(Integer day) {
        return Date.newInstance(2026, 1, day);
    }

    @IsTest
    static void testSchedulerProcessesEligibleRecords() {
      Month__c monthRec;
        List<Month__c> existingMonths = [
            SELECT Id, Name, Year__c, Month_Number__c
            FROM Month__c
            WHERE Year__c != null
              AND Month_Number__c != null
            LIMIT 1
        ];

        if (!existingMonths.isEmpty()) {
            monthRec = existingMonths[0];
        } else {
            Year__c yr = new Year__c(Name = '2026');
            insert yr;

            monthRec = new Month__c(
                Name = 'January 2026 (Test)',
                Year__c = yr.Id,
                Month_Number__c = 1
            );
            insert monthRec;
        }

        Week__c w1 = new Week__c(
            Name = 'Week 1, 2026',
            Month__c = monthRec.Id,
            Week_Number__c = 1
        );
        insert w1;

        Staging_Day__c s = new Staging_Day__c(
            Status__c 		= 'Ready to Process',
            Date__c        = makeDate(2),
            Week_String__c = w1.Name
        );
        insert s;

        Test.startTest();

        // --- Schedule the job (this causes execute() to run in tests) ---
        String cron = '0 0 1 * * ?';
        System.schedule(
            'Day Promotion Scheduler Test',
            cron,
            new DayPromotionScheduler()
        );

        Test.stopTest();

        // --- Assertions ---
        s = [
            SELECT Status__c, Day__c
            FROM Staging_Day__c
            WHERE Id = :s.Id
        ];

        System.assertEquals(
            'Processed',
            s.Status__c,
            'Staging record should be marked Processed'
        );
        System.assertNotEquals(
            null,
            s.Day__c,
            'Day__c lookup should be populated'
        );
    }
}