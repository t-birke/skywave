public with sharing class SDO_Analytics_DataStreamNavigator {

    @AuraEnabled(cacheable=true)
    public static String getDataStreamId(String dataStreamName) {
        try {
            if (String.isBlank(dataStreamName)) {
                return null;
            }

            List<DataStream> dataStreams = [
                SELECT Id
                FROM DataStream
                WHERE Name = :dataStreamName
                LIMIT 1
            ];

            return dataStreams.isEmpty() ? null : dataStreams[0].Id;

        } catch (Exception e) {
            throw new AuraHandledException('Error querying Data Stream: ' + e.getMessage());
        }
    }
}
