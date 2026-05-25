public with sharing class Demo_HelloService {

    public class Request {
        @InvocableVariable(required=true label='Name')
        public String name;
    }

    public class Response {
        @InvocableVariable
        public Boolean success;

        @InvocableVariable(label='Hello Card' description='Structured payload for the Demo Hello LWC renderer.')
        public Demo_HelloData hello;

        @InvocableVariable
        public String narrative;
    }

    @InvocableMethod(label='Demo Hello' description='Greet the user with a custom-rendered card.')
    public static List<Response> execute(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response r = new Response();
            String safe = (req.name == null ? 'world' : req.name);
            String json = JSON.serialize(new Map<String, Object>{
                'greeting' => 'Hello, ' + safe + '!',
                'when' => System.now().format()
            });
            r.hello = new Demo_HelloData(json);
            r.narrative = 'Said hello to ' + safe + '.';
            r.success = true;
            responses.add(r);
        }
        return responses;
    }
}
