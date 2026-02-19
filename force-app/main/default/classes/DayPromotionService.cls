public without sharing class DayPromotionService {
    public static final Integer ERROR_MAX_LEN = 254;

    private static final String STATUS_PROCESSED = 'Processed';
    private static final String STATUS_NOT_READY = 'Not Ready to Process';

    private static final String SKIP_PREFIX = 'Skipped: ';
    private static final String SKIP_NOT_READY_SENTINEL = 'SKIP_NOT_READY';

    public class Result {
        @AuraEnabled public Id stagingId;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public Id dayId;

        public Result() {}

        public Result(Id stagingId, Boolean success, String message, Id dayId) {
            this.stagingId = stagingId;
            this.success = success;
            this.message = message;
            this.dayId = dayId;
        }
    }

    private static Result ok(Id stagingId, Id dayId, String msg) {
        return new Result(stagingId, true, msg, dayId);
    }

    private static Result fail(Id stagingId, String msg) {
        return new Result(stagingId, false, msg, null);
    }

    public static Result promoteOne(Id stagingId) {
        if (stagingId == null) {
            return fail(null, 'No Staging_Day__c Id provided.');
        }
        List<Result> results = promoteMany(new List<Id>{ stagingId });
        return results.isEmpty() ? fail(stagingId, 'No result returned.') : results[0];
    }

    public static List<Result> promoteMany(List<Id> stagingIds) {
        List<Result> out = new List<Result>();
        if (stagingIds == null || stagingIds.isEmpty()) return out;

        // 1) Load staging rows
        List<Staging_Day__c> stagingRows = [
            SELECT Id,
                   Day__c,
                   Month__c,
                   Status__c,
                   Processing_Error__c,
                   Day_Number__c,
                   Week_String__c,
                   Breakfast__c,
                   Calories__c,
                   Calories_Burned__c,
                   Drinks__c,
                   Liters_of_Water__c,
                   Daily_Points_Scored__c,
                   Number_of_Pushups__c,
                   Daily_Rating__c,
                   Steps__c,
                   Dinner__c,
                   Fat__c,
                   Incomplete_Food_Log__c,
                   Lunch__c,
                   Minutes_of_Reading__c,
                   Minutes_of_TV__c,
                   Carbs__c,
                   Protein__c,
                   Screen_Time__c,
                   Sleep_Time__c,
                   Total_Daily_Points__c
              FROM Staging_Day__c
             WHERE Id IN :stagingIds
             FOR UPDATE
        ];

        // Missing ids -> immediate failures
        Set<Id> foundIds = new Set<Id>();
        for (Staging_Day__c s : stagingRows) foundIds.add(s.Id);
        for (Id requestedId : stagingIds) {
            if (!foundIds.contains(requestedId)) {
                out.add(fail(requestedId, 'Staging_Day__c record not found.'));
            }
        }
        if (stagingRows.isEmpty()) return out;

        // 2) Validate and collect week names
        Map<Id, String> validationByStagingId = new Map<Id, String>();
        Set<String> weekNames = new Set<String>();

        for (Staging_Day__c s : stagingRows) {
            if (s.Status__c == STATUS_PROCESSED) {
                validationByStagingId.put(s.Id, 'This staging record is already marked Processed.');
                continue;
            }
            if (s.Status__c == STATUS_NOT_READY) {
                validationByStagingId.put(s.Id, SKIP_NOT_READY_SENTINEL);
                continue;
            }
            if (s.Day_Number__c == null) {
                validationByStagingId.put(s.Id, 'Day_Number__c is blank (required).');
                continue;
            }
            if (String.isBlank(s.Week_String__c)) {
                validationByStagingId.put(s.Id, 'Week_String__c is blank (must match Week__c.Name).');
                continue;
            }
            weekNames.add(s.Week_String__c.trim());
        }

        // 3) Query Weeks in one query and detect duplicates without AggregateResult
        Map<String, Week__c> weekByName = new Map<String, Week__c>();
        Map<String, Integer> weekCounts = new Map<String, Integer>();

        if (!weekNames.isEmpty()) {
            for (Week__c w : [
                SELECT Id, Name, Month__c
                  FROM Week__c
                 WHERE Name IN :weekNames
            ]) {
                weekCounts.put(w.Name, (weekCounts.containsKey(w.Name) ? weekCounts.get(w.Name) : 0) + 1);
                // keep first; duplicates handled via weekCounts
                if (!weekByName.containsKey(w.Name)) {
                    weekByName.put(w.Name, w);
                }
            }
        }

        // 4) Build match keys; collect WeekIds + DayNumbers for Day__c query
        Map<Id, String> keyByStagingId = new Map<Id, String>();
        Set<Id> weekIds = new Set<Id>();
        Set<Decimal> dayNums = new Set<Decimal>();

        for (Staging_Day__c s : stagingRows) {
            if (validationByStagingId.containsKey(s.Id)) continue;

            String weekName = s.Week_String__c.trim();
            Integer c = weekCounts.get(weekName);

            if (c == null || c == 0) {
                validationByStagingId.put(s.Id, 'No Week__c found with Name = "' + weekName + '".');
                continue;
            }
            if (c > 1) {
                validationByStagingId.put(s.Id, 'Multiple Week__c records found with Name = "' + weekName + '". Name must be unique.');
                continue;
            }

            Week__c wk = weekByName.get(weekName);
            if (wk == null) {
                validationByStagingId.put(s.Id, 'No Week__c found with Name = "' + weekName + '".');
                continue;
            }
            if (wk.Month__c == null) {
                validationByStagingId.put(s.Id, 'Week__c "' + wk.Name + '" has no Month__c, but Day__c.Month__c is required.');
                continue;
            }

            String key = dayKey(wk.Id, s.Day_Number__c);
            keyByStagingId.put(s.Id, key);

            weekIds.add(wk.Id);
            dayNums.add(s.Day_Number__c);
        }

        // 5) Query existing Day__c and detect duplicates for (Week, DayNumber)
        Map<String, Day__c> dayByKey = new Map<String, Day__c>();
        Map<String, Integer> dayKeyCounts = new Map<String, Integer>();

        if (!weekIds.isEmpty() && !dayNums.isEmpty()) {
            List<Day__c> existingDays = [
                SELECT Id, Week__c, Day_Number__c, Month__c
                  FROM Day__c
                 WHERE Week__c IN :weekIds
                   AND Day_Number__c IN :dayNums
                 // FOR UPDATE  // keep only if you truly need it
            ];

            for (Day__c d : existingDays) {
                String key = dayKey(d.Week__c, d.Day_Number__c);
                dayKeyCounts.put(key, (dayKeyCounts.containsKey(key) ? dayKeyCounts.get(key) : 0) + 1);
                if (!dayByKey.containsKey(key)) {
                    dayByKey.put(key, d);
                }
            }
        }

        for (Staging_Day__c s : stagingRows) {
            String key = keyByStagingId.get(s.Id);
            if (key == null) continue;

            Integer c = dayKeyCounts.get(key);
            if (c != null && c > 1) {
                Week__c wk = weekByName.get(s.Week_String__c.trim());
                validationByStagingId.put(
                    s.Id,
                    'Multiple Day__c records exist for Day_Number__c=' + String.valueOf(s.Day_Number__c) +
                    ' and Week__c="' + (wk != null ? wk.Name : '(unknown)') + '". This combination must be unique.'
                );
            }
        }

        // 6) Build Day__c DML list
        List<Day__c> daysToUpsert = new List<Day__c>();
        List<Id> stagingIdsInDmlOrder = new List<Id>();
        Map<Id, Boolean> isUpdateByStagingId = new Map<Id, Boolean>();

        for (Staging_Day__c s : stagingRows) {
            if (validationByStagingId.containsKey(s.Id)) continue;

            Week__c wk = weekByName.get(s.Week_String__c.trim());
            String key = dayKey(wk.Id, s.Day_Number__c);

            Day__c existing = dayByKey.get(key);
            Boolean isUpdate = (existing != null);
            isUpdateByStagingId.put(s.Id, isUpdate);

            Day__c d = isUpdate ? new Day__c(Id = existing.Id) : new Day__c();

            // Insert-only “key” fields
            if (!isUpdate) {
                d.Day_Number__c = s.Day_Number__c;
                d.Week__c       = wk.Id;       // master-detail parent set only on insert
                d.Month__c      = wk.Month__c; // set only on insert
            }

            // Mappings (overwrite)
            d.Breakfast__c                    = s.Breakfast__c;
            d.Calories__c                     = s.Calories__c;
            d.Calories_Burned__c              = s.Calories_Burned__c;
            d.Daily_Alcoholic_Drinks_Drank__c = s.Drinks__c;
            d.Daily_Liters_of_Water_Drank__c  = s.Liters_of_Water__c;
            d.Daily_Points_Scored__c          = s.Daily_Points_Scored__c;
            d.Daily_Pushups__c                = s.Number_of_Pushups__c;
            d.Daily_Rating__c                 = s.Daily_Rating__c;
            d.Daily_Steps__c                  = s.Steps__c;
            d.Dinner__c                       = s.Dinner__c;
            d.Fat__c                          = s.Fat__c;
            d.Incomplete_Food_Log__c          = s.Incomplete_Food_Log__c;
            d.Lunch__c                        = s.Lunch__c;
            d.Minutes_of_Reading__c           = s.Minutes_of_Reading__c;
            d.Minutes_of_TV__c                = s.Minutes_of_TV__c;
            d.Net_Carbs__c                    = s.Carbs__c;
            d.Protein__c                      = s.Protein__c;
            d.Screen_Time__c                  = s.Screen_Time__c;
            d.Sleep_Time__c                   = s.Sleep_Time__c;
            d.Total_Daily_Points__c           = s.Total_Daily_Points__c;

            daysToUpsert.add(d);
            stagingIdsInDmlOrder.add(s.Id);
        }

        // 7) Upsert Day__c and build results
        Map<Id, Result> resultByStagingId = new Map<Id, Result>();

        if (!daysToUpsert.isEmpty()) {
            Database.UpsertResult[] upResults = Database.upsert(daysToUpsert, false);

            for (Integer i = 0; i < upResults.size(); i++) {
                Id stagingId = stagingIdsInDmlOrder[i];
                Database.UpsertResult ur = upResults[i];

                if (ur.isSuccess()) {
                    Boolean wasUpdate = isUpdateByStagingId.get(stagingId);
                    String msg = wasUpdate ? 'Updated Day__c.' : 'Created Day__c.';
                    resultByStagingId.put(stagingId, ok(stagingId, ur.getId(), msg));
                } else {
                    resultByStagingId.put(stagingId, fail(stagingId, truncateError(firstErrorMessage(ur))));
                }
            }
        }

        // Validation failures / skips
        for (Id sId : validationByStagingId.keySet()) {
            String msg = validationByStagingId.get(sId);

            if (msg == SKIP_NOT_READY_SENTINEL) {
                resultByStagingId.put(sId, ok(sId, null, SKIP_PREFIX + 'Status is "Not Ready to Process".'));
            } else {
                resultByStagingId.put(sId, fail(sId, truncateError(msg)));
            }
        }

        // Month lookup for successful results
        Set<Id> successfulDayIds = new Set<Id>();
        for (Result r : resultByStagingId.values()) {
            if (r != null && r.success == true && r.dayId != null) successfulDayIds.add(r.dayId);
        }

        Map<Id, Id> monthIdByDayId = new Map<Id, Id>();
        if (!successfulDayIds.isEmpty()) {
            for (Day__c dRec : [SELECT Id, Month__c FROM Day__c WHERE Id IN :successfulDayIds]) {
                monthIdByDayId.put(dRec.Id, dRec.Month__c);
            }
        }

        // 8) Update staging (skip means NO DML)
        List<Staging_Day__c> stagingToUpdate = new List<Staging_Day__c>();

        for (Staging_Day__c s : stagingRows) {
            Result r = resultByStagingId.get(s.Id);
            if (r == null) continue;

            Boolean isSkipped = (r.dayId == null && r.message != null && r.message.startsWith(SKIP_PREFIX));
            if (isSkipped) continue;

            Staging_Day__c upd = new Staging_Day__c(Id = s.Id);

            if (r.success) {
                upd.Status__c = STATUS_PROCESSED;
                upd.Processing_Error__c = null;
                upd.Day__c = r.dayId;
                upd.Month__c = monthIdByDayId.get(r.dayId);
            } else {
                upd.Processing_Error__c = truncateError(r.message);
            }

            stagingToUpdate.add(upd);
        }

        if (!stagingToUpdate.isEmpty()) {
            update stagingToUpdate;
        }

        // 9) Output in caller order
        for (Id sId : stagingIds) {
            if (resultByStagingId.containsKey(sId)) {
                out.add(resultByStagingId.get(sId));
            }
        }
        return out;
    }

    private static String dayKey(Id weekId, Decimal dayNumber) {
        return String.valueOf(weekId) + '|' + String.valueOf(dayNumber);
    }

    private static String firstErrorMessage(Database.UpsertResult ur) {
        if (ur == null) return 'Unknown error.';
        Database.Error[] errs = ur.getErrors();
        if (errs == null || errs.isEmpty()) return 'Unknown error.';
        return errs[0].getStatusCode() + ': ' + errs[0].getMessage();
    }

    private static String truncateError(String msg) {
        if (String.isBlank(msg)) return msg;
        String trimmed = msg.trim();
        return (trimmed.length() <= ERROR_MAX_LEN) ? trimmed : trimmed.substring(0, ERROR_MAX_LEN);
    }
}