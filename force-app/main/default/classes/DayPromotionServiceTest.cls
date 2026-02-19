@IsTest
private class DayPromotionServiceTest {

    /* Utility: create a valid Date that yields a specific day-of-month */
    private static Date makeDate(Integer day) {
        return Date.newInstance(2026, 1, day);
    }

    /* Fake Id generator for "record not found" path */
    private static Id fakeId(String keyPrefix) {
        return (Id)(keyPrefix + '000000000000AAA');
    }

    private static String promotableStatus() {
        // Find a picklist value that is NOT one of the blocked statuses
        Schema.DescribeFieldResult d = Staging_Day__c.Status__c.getDescribe();
        for (Schema.PicklistEntry pe : d.getPicklistValues()) {
            String v = pe.getValue();
            if (v != 'Not Ready to Process' && v != 'Processed') {
                return v;
            }
        }
        // If the picklist only has those two values (unlikely), fall back to null
        return null;
    }

    @testSetup
    static void setupData() {
        // Prefer using an existing Month__c that already satisfies required fields:
        // - Year__c (lookup) is populated
        // - Month_Number__c is populated
        Month__c monthRec;
        String readyStatus = promotableStatus();

        // Optional but helpful: if this fails, your Status__c picklist only has the two blocked values.
        System.assertNotEquals(null, readyStatus, 'No promotable Status__c picklist value exists.');

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

        // Existing Day__c -> update path
        insert new Day__c(
            Week__c       = w1.Id,
            Month__c      = monthRec.Id,
            Day_Number__c = 1
        );

        // Staging rows (Day_Number__c is a formula from Date__c, so set Date__c)
        List<Staging_Day__c> rows = new List<Staging_Day__c>{
            // INSERT path
            new Staging_Day__c(
                Status__c      = readyStatus,
                Date__c        = makeDate(2),
                Week_String__c = w1.Name,
                Breakfast__c   = 'Bagel',
                Calories__c    = 400
            ),

            // UPDATE path
            new Staging_Day__c(
                Status__c      = readyStatus,
                Date__c        = makeDate(1),
                Week_String__c = w1.Name,
                Breakfast__c   = 'Cereal'
            ),

            // Already processed -> validation failure
            new Staging_Day__c(
                Status__c      = 'Processed',
                Date__c        = makeDate(3),
                Week_String__c = w1.Name
            ),

            // Not ready -> skipped
            new Staging_Day__c(
                Status__c           = 'Not Ready to Process',
                Date__c             = makeDate(4),
                Week_String__c      = w1.Name,
                Processing_Error__c = 'Preserve me'
            ),

            // Missing Date__c -> Day_Number__c formula evaluates to null -> validation failure
            new Staging_Day__c(
                Week_String__c = w1.Name
            ),

            // Blank Week_String__c -> validation failure
            new Staging_Day__c(
                Date__c        = makeDate(5),
                Week_String__c = '   '
            ),

            // Week not found
            new Staging_Day__c(
                Status__c      = readyStatus,
                Date__c        = makeDate(6),
                Week_String__c = 'Week ' + 'X'.repeat(2) + ', 2026'
            )
        };

        insert rows;
    }

    @IsTest
    static void testPromoteOne_null() {
        DayPromotionService.Result r = DayPromotionService.promoteOne(null);
        System.assertEquals(false, r.success);
        System.assertEquals(null, r.dayId);
        System.assert(r.message != null && r.message.contains('No Staging_Day__c Id provided.'));
    }

    @IsTest
    static void testPromoteMany_allPaths() {
        List<Staging_Day__c> staging = [
            SELECT Id, Status__c, Date__c, Week_String__c, Processing_Error__c, Breakfast__c, Calories__c
            FROM Staging_Day__c
        ];

        Id insertId, updateId, alreadyProcessedId, notReadyId, missingDateId, blankWeekId, weekNotFoundId;

        for (Staging_Day__c s : staging) {
            if (s.Date__c == makeDate(2) && s.Breakfast__c == 'Bagel' && s.Calories__c == 400 && s.Week_String__c == 'Week 1, 2026') {
                insertId = s.Id;
            } else if (s.Date__c == makeDate(1) && s.Breakfast__c == 'Cereal' && s.Week_String__c == 'Week 1, 2026') {
                updateId = s.Id;
            } else if (s.Status__c == 'Processed') {
                alreadyProcessedId = s.Id;
            } else if (s.Status__c == 'Not Ready to Process' && s.Processing_Error__c == 'Preserve me') {
                notReadyId = s.Id;
            } else if (s.Date__c == null && s.Week_String__c == 'Week 1, 2026') {
                missingDateId = s.Id;
            } else if (String.isBlank(s.Week_String__c) && s.Date__c == makeDate(5)) {
                blankWeekId = s.Id;
            } else if (s.Date__c == makeDate(6) && s.Week_String__c != null && s.Week_String__c.startsWith('Week ')) {
                weekNotFoundId = s.Id;
            }
        }

        System.assertNotEquals(null, insertId, 'Could not locate INSERT staging row');
        System.assertNotEquals(null, updateId, 'Could not locate UPDATE staging row');
        System.assertNotEquals(null, alreadyProcessedId, 'Could not locate Processed staging row');
        System.assertNotEquals(null, notReadyId, 'Could not locate Not Ready staging row');
        System.assertNotEquals(null, missingDateId, 'Could not locate missing Date__c staging row');
        System.assertNotEquals(null, blankWeekId, 'Could not locate blank Week_String__c staging row');
        System.assertNotEquals(null, weekNotFoundId, 'Could not locate week-not-found staging row');

        Id missingId = fakeId(Staging_Day__c.SObjectType.getDescribe().getKeyPrefix());

        List<Id> ids = new List<Id>{
            missingId,
            insertId,
            updateId,
            alreadyProcessedId,
            notReadyId,
            missingDateId,
            blankWeekId,
            weekNotFoundId
        };

        Test.startTest();
        List<DayPromotionService.Result> results = DayPromotionService.promoteMany(ids);
        Test.stopTest();

        Map<Id, DayPromotionService.Result> byId = new Map<Id, DayPromotionService.Result>();
        for (DayPromotionService.Result r : results) byId.put(r.stagingId, r);

        System.assertEquals(true, byId.get(insertId).success, byId.get(insertId).message);
        System.assertEquals('Created Day__c.', byId.get(insertId).message);

        System.assertEquals(true, byId.get(updateId).success, byId.get(updateId).message);
        System.assertEquals('Updated Day__c.', byId.get(updateId).message);

        System.assertEquals(true, byId.get(notReadyId).success);
        System.assert(byId.get(notReadyId).message.startsWith('Skipped: '), byId.get(notReadyId).message);
    }
}