public with sharing class SDO_Analytics_SessionAudio {

    private static final Set<String> ACCEPTED_AUDIO_EXTENSIONS = new Set<String>{
        'mp3', 'wav', 'ogg', 'webm', 'm4a', 'aac', 'flac', 'opus'
    };

    @AuraEnabled(cacheable=true)
    public static List<String> getAcceptedAudioFormats() {
        List<String> formats = new List<String>();
        for (String ext : ACCEPTED_AUDIO_EXTENSIONS) {
            formats.add('.' + ext);
        }
        return formats;
    }

    @AuraEnabled(cacheable=false)
    public static VoiceCallRecordingResult getVoiceCallRecording(String voiceCallId) {
        VoiceCallRecordingResult result = new VoiceCallRecordingResult();

        if (String.isBlank(voiceCallId)) {
            result.error = 'No Voice Call ID provided';
            return result;
        }

        try {
            List<VoiceCall> voiceCalls = [
                SELECT Id, CallStartDateTime, CallEndDateTime, CallDurationInSeconds,
                       FromPhoneNumber, ToPhoneNumber, CallRecordingId,
                       CallRecording.Id, CallRecording.Name, CallRecording.MediaContentId,
                       CallRecording.DurationInSeconds
                FROM VoiceCall
                WHERE Id = :voiceCallId
                LIMIT 1
            ];

            if (voiceCalls.isEmpty()) {
                result.error = 'Voice Call record not found';
                return result;
            }

            VoiceCall voiceCall = voiceCalls[0];
            result.voiceCallStartTime = voiceCall.CallStartDateTime;
            result.voiceCallEndTime = voiceCall.CallEndDateTime;
            result.callDuration = voiceCall.CallDurationInSeconds;
            result.fromPhoneNumber = voiceCall.FromPhoneNumber;
            result.toPhoneNumber = voiceCall.ToPhoneNumber;

            if (voiceCall.CallRecordingId == null) {
                result.hasVoiceCallRecording = false;
                result.error = 'No recording found for this voice call';
                return result;
            }

            result.hasVoiceCallRecording = true;
            result.durationInSeconds = voiceCall.CallRecording.DurationInSeconds;

            if (voiceCall.CallRecording.MediaContentId == null) {
                result.error = 'Recording exists but has no value in MediaContentId';
                return result;
            }

            List<ContentDocument> documents = [
                SELECT Id, Title, FileExtension, FileType, ContentSize, LatestPublishedVersionId
                FROM ContentDocument
                WHERE Id = :voiceCall.CallRecording.MediaContentId
                LIMIT 1
            ];

            if (documents.isEmpty()) {
                result.error = 'Media content not found';
                return result;
            }

            ContentDocument doc = documents[0];

            if (!isAudioFile(doc.FileExtension, doc.FileType)) {
                result.error = 'File is not a compatible audio format. Found: ' + doc.FileType;
                return result;
            }

            result.contentDocumentId = doc.Id;
            result.contentVersionId = doc.LatestPublishedVersionId;
            result.title = doc.Title;
            result.fileExtension = doc.FileExtension;
            result.fileType = doc.FileType;
            result.fileSize = doc.ContentSize;

        } catch (Exception e) {
            result.error = 'Error retrieving recording: ' + e.getMessage();
        }

        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<AudioFileOption> getAvailableAudioFiles() {
        List<AudioFileOption> options = new List<AudioFileOption>();

        try {
            List<ContentDocument> documents = [
                SELECT Id, Title, FileExtension, FileType, ContentSize, CreatedDate
                FROM ContentDocument
                WHERE FileExtension IN :ACCEPTED_AUDIO_EXTENSIONS
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];

            for (ContentDocument doc : documents) {
                AudioFileOption option = new AudioFileOption();
                option.value = doc.Id;
                option.label = doc.Title + '.' + doc.FileExtension + ' (' + formatFileSize(doc.ContentSize) + ')';
                option.title = doc.Title;
                option.fileExtension = doc.FileExtension;
                option.fileSize = doc.ContentSize;
                options.add(option);
            }
        } catch (Exception e) {
            System.debug('Error retrieving audio files: ' + e.getMessage());
        }

        return options;
    }

    @AuraEnabled
    public static String updateVoiceCallRecordingMedia(String voiceCallId, String contentDocumentId) {
        if (String.isBlank(voiceCallId)) {
            return 'No Voice Call ID provided';
        }

        if (String.isBlank(contentDocumentId)) {
            return 'No Content Document ID provided';
        }

        try {
            List<VoiceCall> voiceCalls = [
                SELECT CallRecordingId
                FROM VoiceCall
                WHERE Id = :voiceCallId
                LIMIT 1
            ];

            if (voiceCalls.isEmpty()) {
                return 'Voice Call not found';
            }

            if (voiceCalls[0].CallRecordingId == null) {
                return 'No VoiceCallRecording found for this Voice Call';
            }

            VoiceCallRecording recording = new VoiceCallRecording(
                Id = voiceCalls[0].CallRecordingId,
                MediaContentId = contentDocumentId
            );
            update recording;

            return null;
        } catch (Exception e) {
            return 'Error updating recording: ' + e.getMessage();
        }
    }

    private static Boolean isAudioFile(String extension, String fileType) {
        Set<String> audioMimeTypes = new Set<String>{
            'AUDIO', 'audio/mpeg', 'audio/wav', 'audio/ogg',
            'audio/webm', 'audio/mp4', 'audio/aac', 'audio/flac'
        };

        return (extension != null && ACCEPTED_AUDIO_EXTENSIONS.contains(extension.toLowerCase())) ||
               (fileType != null && (audioMimeTypes.contains(fileType) || fileType.toLowerCase().startsWith('audio')));
    }

    private static String formatFileSize(Integer bytes) {
        if (bytes == null) return '0 B';
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1048576) return String.valueOf(bytes / 1024) + ' KB';
        return String.valueOf(bytes / 1048576) + ' MB';
    }

    public class VoiceCallRecordingResult {
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String contentVersionId;
        @AuraEnabled public String title;
        @AuraEnabled public String fileExtension;
        @AuraEnabled public String fileType;
        @AuraEnabled public Integer fileSize;
        @AuraEnabled public Integer durationInSeconds;
        @AuraEnabled public DateTime voiceCallStartTime;
        @AuraEnabled public DateTime voiceCallEndTime;
        @AuraEnabled public Integer callDuration;
        @AuraEnabled public String fromPhoneNumber;
        @AuraEnabled public String toPhoneNumber;
        @AuraEnabled public Boolean hasVoiceCallRecording;
        @AuraEnabled public String error;
    }

    public class AudioFileOption {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
        @AuraEnabled public String title;
        @AuraEnabled public String fileExtension;
        @AuraEnabled public Integer fileSize;
    }
}
