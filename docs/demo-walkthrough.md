# Skywave interactive

**purpose: make the audience feel what is so unique about Agentforce**

Ok, I once heard there was an airline. They took 6 months to launch a prototype agent on their website. But when trying to make changes to their flights, or book a new one, the agent just blanked. It could basically only read the FAQs.
I wish, they did build their Agent with Agentforce.

Now what is so special about Agentforce? (Ask audience, steer towards:)
What I see are three things - State, Scaffolding and Script.

**State** meaning, the agent knows what it did, it has variables that survive the session and exactly define what has happend, what is possible and what is next.

This ties directly in with Agent **Script** - a domain specific language that controls what is being reasoned by the LLM based on state and deterministic controls.

And finally, **Scaffolding** An Agent is not just what we cobbled together by some loose code. An Agent needs a scaffolding, it needs infrastructure around it. It needs security, testing, monitoring, tracing, alerting.

Now but what is the biggest Agentforce advantag? Right, the fact that it is built on the Salesforce platform.
This gives us some unique features hard to recreate.
Most of our customers have years, even decades of built process automation in salesforce, flows, apex classes, things that do stuff. So now we can extend these as actions to our agents and thus make the agents capable of getting things done. So I call this **Action**.

We also have Data 360, our real time data platform that can connect all your data and relate it to the heart of your business, your customers. Together with it's capabilities to manage unstructured data this creates an incredible deep data foundation that we need as **context** for our agents. 

And my most favourite platform feature: everything is completely headless! This means, agents can easily understand your setup and add to your configuration. This results in incredible **speed**

All of this sounds nice. But what does it really mean? Also sounds hollow, like everyone can say that about their Agent Platform. But this is real, and I am going to show you. And hopefully, by the end of this presentation, you will not only have heard these things, but EXPERIENCED them yourself and actually BELIEVE them.

## Chapter 1 - generate data

Take out your phones.
If you scan this QR code, you will be redirected to the Skywaves Website. If you give consent, you will be led to a survey. Now this is a necessity, what this is simulating is you browsing the skywave website, and even though these are survey answers, we log them through our interaction sdk and build a realtime anonymous profile about you. And if you ask, what does this have to do with agentforce, bear with me, it will make sense in a moment!

(presenter hints at monitor) So as you can see, we generate a whole bunch of new cookies today, and as soon as you click through the survey, these are no longer just cookie ids, but these are preferences. And if we know that, why shouldn't we use that, right? We could for example personalise the skywave website based on this, and the next time you come back, it is actually personalised already with that dream flight of yours???

## Chapter 2 - get to know the skywave agent

BUT, let me move this to the next stage, you should now all see the skywave agent down here. If you want, you can interact with it, if you are like me and CANNOT do 2 things at the same time, just listen. So I can ask this agent stuff about the experience flying skywave or whatever, and it is instructed to use my profile to make useful recommendations, so it asks me if I want to book a flight to new york. And just check how personalised this agent is, it knows what you like, before it knows who you actually are - let that sink in - deep user context even in an anonymous session.

Allright, I am intrigued and go book that flight. And if you want to follow along, you can also directly instruct the agent to create a flight, it will set you up. 

## Chapter 3 - Account creation

Now obviously now we need to handover some personal data for the booking to occur, so let's do this (option a - create account with agent interview and some nice HXL components) or (option b - lead to a page to create the account)

Hint: if you enter a valid phone numner, maybe we might even switch channels later.

And if you want to fully enjoy the demo, you even create a profile picture. I know, like everybody would do this when booking a first flight with an airline ... but you will see your avatar pop up on the screen, so that's the point.

(presenter switches monitor to C360 view in Sales Cloud)
Now check this rich profile we have already gathered, this is our full Customer 360 truth, we can see what the customer is interested in, what led to these conclusions, all the events...amazing

## Chapter 4 - (optional) Deep dive into Data 360
TBD
what powers this? explain Data Streams, RT DG, IR, Segments

## Chapter 5 - Seat Change
Now, you have a booked flight, you have an account. But do you know what? You forgot to assign a seat. Because I deliberatly removed that option from the flow, so that we have something to talk about for the rest of the demo.

Ok, now let's go back to the website, talk to the agent, try to get a seat.
(types: I need to get a seat for the flight I booked)

oh no. See that? The agent is nasty, it cannot get me a seat.

## Chapter 6 - Observability

Let's get to our observability. Here in Agentforce Studio we can see all the requests this agent gets and how satisfactory it's answers are. What directly jumps into my eye is the seat change intent. So this is a real gap. Let's drill down, and while we are at it, see how the agent actually works.
This detailed log is existing for every conversation the agent ever has! And you can literally watch it think. Whenever you see this lightning symbol, you know it executed an action,
observe this: 
And because we have State and saved your booking to a variable, with this action we do not need to ask that again, it is directly available to the agent as context, no guesswork, no llm involved

 and this are reasoning steps. If you are interested what is the actual prompt that gets send to the llm and what the response is...you will find it here!

Ok, as expected, agent does not find an action to change seats and there are no instructions how to handle it, so it correctly diverts to the off-topic subagent.



## Chapter 7 - Create a new subagent with Claude

Ok, you know how they build agents these days right? Other agents...Coding agents. So let's dive into claude code.  I have some things setup, my machine is connected to my org via sf dx and I gave claude some skills, that are all available on our public website.

So let's give it a simple instruction. ``` Extend the skywave agent with the capability to book and change seats ````
So off claude goes. But because the whole salesforce platform is available headlessly to agents and all knowledge is encoded in metadata, the platform is legible to claud! It can very quickly find out what I mean by these ambiguous instructions. It finds out that there already is an Apex class that is used by our help desk agents to assign and change seats and it also knows the agent shape and how to integrate this. So as claude comes up with a plan, I really like it, and tell it to go do it.

----
(Do the following while claude is building)
Now if we head over to Agent Studio, we can see how our agent is built. 
So let’s take a moment to explore how agents are defined.
Beyond the name and description of our agent...
Are the system level configurations that help the agent understand it’s role, how it should greet users, and how it should respond to errors.
And inside Language Settings are all the languages, that the agent is entitled to respond with...
And the subagents Agentforce will use to do this job. Let's talk about 2 of them...
This Agent Router is how you'll configure your agent to select the appropriate subagent for each customer interaction. 
And this Escalation subagent is how Agentforce enables seamless handoff to human employees inside Salesforce
Meanwhile, Variables give your agent memory and persistance across multi-turn interactions. And notice, that Agentforce has  variables related to verification and contacts built in — which makes it aware of your customers — by default.
And in Connections — you define where your agents can engage -- which might include web, mobile, email or even voice. 
And Data Library — this is where Agentforce makes it easy to setup a RAG pipeline for the unstructured knowledge you already have in Salesforce or Data 360.

And all of these definitions look like this in the canvas view, because we like to think in documents. But actually, this is just a representation of agent script, our domain specific language to describe agents. And this is what claude sees too, just check this, this is the seat change subagent it added.

<TODO: find an example to nail determinism>
And this is how script deterministically ... and only leads the very narrow input to reason

Now this is real Speed! How much time did it take to extend our agents capabilities? 3 minutes? This is crazy, and all, because our coding agent knows our platform ....BECAUSE....everything is described and wired through metadata.

## Chapter 8 - Build out some tests
Ok, but now, would you trust this agent with the changes we did? I wouldn't...and this is why we have testing center, where we can build test suites that thoroughly run through all possible things a user could throw at the agent. These can be agentically generated and extended as well and once this runs satisfactory, that is when we can release the new version of our agent!

And this is how the scaffolding around the agent ensures that we can confidently deploy it and put it in front of real customers. And when it is operating live, we want to have that rich observability and that trust that the agent can only do on behalf of the users what the users could do themselves calling into our callcenter.

## Chapter 9 - The Real Seat Change
So we are about to test the seat change again. But you know what? The agent is multimodal. So we could also have a conversation with it on whatsapp, or on the phone, if you have entered your phonenumber.
So is there anyone in the audience who did put in their phone number during the registration? (Pick one) ok, can you please call this number and put your phone on speaker?

.... go through seat change converversation ....


And this is the agent taking Action. Let that sink in. It is allowed to change the seat. But only the combination of agent access AND the user authorisaton to his data makes it possible to take this action. The user could never change the seat for another user nor could the agent change any seat without a user authenticated.


## Chapter 10 - do the race

## Chapter 11 - Results and Wrap Up 


Main Beats




````
Monitoring screen shows a world map with routes of Skywaves flights. As people consent and thus create a cookie, bubbles appear showing the last 8 digits of their cookies.
````
