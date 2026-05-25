@JsonAccess(serializable='always' deserializable='always')
global class Demo_HelloData {

    @AuraEnabled
    global String messageJSON;

    global Demo_HelloData(String messageJSON) {
        this.messageJSON = messageJSON;
    }

    global Demo_HelloData() {
        this.messageJSON = '';
    }
}
