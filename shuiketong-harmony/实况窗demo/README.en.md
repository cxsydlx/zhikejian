# Live View Kit - Instant Delivery

## Overview

Built on HarmonyOS, Live View Kit enables you to create, update, and end live views in multiple scenarios, such as instant delivery. It also provides customizable status nodes tailored to each scenario, helping users quickly focus on key information and enhancing the overall experience.

## Concepts

- Live view: It is a notification form designed to help users focus on ongoing tasks, enabling quick viewing and immediate handling of these tasks. A live view lasts for a specific period of time and features timeliness and dynamic updates.
- Component: Components such as **Text** and **Image** are used in the demo project.
- liveViewManager: This module provides basic capabilities of Live View Kit, including creating, updating, and ending a live view, obtaining a live view, and checking whether the live view function is enabled.

## Preview

### UI Display

On the home page of the sample app, there are cards for multiple scenarios. You can tap a card to go to the page of the corresponding scenario.
You can create, update, and end a live view by tapping the buttons on the scenario page, and view the live view update process in this scenario. (The update process is for reference only. You can customize the process as required.)

| App Home Page                       | Scenario Page (Instant Delivery) | Live View Example (Instant Delivery)   |
|-------------------------------------|----------------------------------|----------------------------------------|
| ![](./screenshots/main_page_en.png) | ![](./screenshots/page_en.png)   | ![](./screenshots/notification_en.png) |

Left-right text template (applicable to air travel and high-speed rail travel): widget background effects such as moon viewing, sunset, and rainy/snowy weather

| Moon-viewing background               | Sunset background                              | Rainy/Snowy weather background                          |
|---------------------------------------|--------------------------------------|------------------------------------|
| ![](./screenshots/flight_moon_en.png) | ![](./screenshots/flight_sunset_en.png) | ![](./screenshots/flight_snow_en.png) |

### Scenarios and States

- Instant delivery: Pending payment, To be accepted by merchant, To be accepted by rider, Accepted by rider, Rider arrived at store, Delivery in progress, Order placed in locker, and Delivered
- Ride hailing: Requesting a car, Trip starting soon, Driver on the way, Driver arrived, Heading to destination, Trip completed, and Pending payment
- High-speed rail travel: Scheduled to depart, Security check completed, Boarding soon, Boarded, Boarding closed, Departed, En route, and Arrived
- Queuing: Number obtained, Queuing, Coming up, Your turn, and Queuing completed
- Live scores: Q1 started, Update I/II/III, Timeout, Timeout ended, Half-time, Q2 started, and Final
- Navigation: Navigation started, Guidance I/II, Route change, and Navigation ended
- Air travel: Scheduled to depart, Pending check-in, Checked in, Security check completed, Boarding started, Last boarding call, Boarded, Boarding closed, About to depart, Departed, Arrived, Baggage claim reminder, Trip completed, Refunded, Canceled, Delayed, and Rescheduled
- Timing: Timing, Countdown, Timing paused, Timing continued, and Timing ended
- Shared leasing: Order submitted, Progress update, Order completed, and Leasing paused
- Meal pickup: Pending payment, Pending confirmation, Preparing, Ready for pickup, Picked up, Completed, and Canceled
- Workout: Started, Update I/II/III, Ended, and Paused

For details about the scenario design specifications, please refer to [Node Design References for Different Application Scenarios](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V5/liveview-design-formula-V5#section596543013594).

## Project Directory

```
├─entry/src/main/ets                // Code area. 
│ ├─components                      // Directory for storing UI components.
│ │ ├─BottomTip.ets                 // Bottom tip component.
│ │ └─InstantPageButton.ets         // Page button component.
│ ├─entryability
│ │ └─EntryAbility.ets              // Entry point class.
│ ├─pages                           // Directory for storing app UI files.
│ │ ├─Index.ets                     // App home page for the live view service.
│ │ ├─InstantDelivery.ets           // Page for instant delivery.
│ │ ├─TaxiHailing.ets               // Page for ride hailing.
│ │ ├─TrainDeparture.ets            // Page for high-speed rail travel.
│ │ ├─QueueingUp.ets                // Page for queuing.
│ │ ├─MatchScore.ets                // Page for live scores.
│ │ ├─Navigation.ets                // Page for navigation.
│ │ ├─FlightTravel.ets              // Page for air travel.
│ │ ├─Timer.ets                     // Page for timing.
│ │ ├─RentShare.ets                 // Page for shared leasing.
│ │ ├─PickUp.ets                    // Page for meal pickup.
│ │ └─Workout.ets                   // Page for workout.
│ ├─utils                           // Directory for storing utility classes.
│ │ ├─ContextUtil.ets               // Context utility class.
│ │ ├─ImageUtil.ets                 // Image utility class.
│ │ ├─LogUtil.ets                   // Log utility class.
│ │ ├─DeliveryLiveViewUtil.ets      // Utility class for the live view of instant delivery.
│ │ ├─TaxiLiveViewUtil.ets          // Utility class for the live view of ride hailing.
│ │ ├─TrainLiveViewUtil.ets         // Utility class for the live view of high-speed rail travel.
│ │ ├─QueueLiveViewUtil.ets         // Utility class for the live view of queuing.
│ │ ├─ScoreLiveViewUtil.ets         // Utility class for the live view of live scores.
│ │ ├─NavigationLiveViewUtil.ets    // Utility class for the live view of navigation.
│ │ ├─FlightLiveViewUtil.ets        // Utility class for the live view of air travel.
│ │ ├─TimerUtil.ets                 // Utility class for the live view of timing.
│ │ ├─RentLiveViewUtil.ets          // Utility class for the live view of shared leasing.
│ │ ├─PickLiveViewUtil.ets          // Utility class for the live view of meal pickup.
│ │ └─WorkoutLiveViewUtil.ets       // Utility class for the live view of workout.
└─entry/src/main/resources          // Directory for storing resource files.
```

## Required Permissions

- To use this demo, replace the value of **bundleName** in the **AppScope/app.json5** file with your own package name.
  ![img.png](screenshots/img.png)
- If your app package does not have the required permissions, refer to the [guide](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V5/liveview-preparations-V5) to enable Push Kit and Live View Kit first.
- If you need to download images over the Internet, add the **"name": "ohos.permission.INTERNET"** permission to the **requestPermissions** section in the **module.json5** file, as shown in the following figure.
  ![](./screenshots/modlue_json5_img.png)

## How to Use

1. This demo provides only the capabilities of creating, updating, and ending live views locally, but does not support background updates. To enable background updates, please use Push Kit. To update live views through Push Kit, use the existing app server to call the corresponding REST API by referring to [Pushing a Live View Message](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V5/push-update-liveview-V5).
2. On the **LiveView Experience** page, tap **Instant Delivery**.
3. On the **Instant Delivery** page, tap **Submitting an Order** to create a live view displaying the **Pending payment** state.
4. After creating the live view, tap **Update Progress** to update the live view. By default, the live view is automatically updated every 15 seconds.
5. Tap **End Order** to end the lifecycle of the current live view. You can tap **Submitting an Order** to create another live view after the 15-second retention period expires.
6. The process in other scenarios is similar to that in the **instant delivery** scenario. This demo demonstrates the widget styles and update processes in different scenarios.
7. You can customize the content and style of live view widgets and capsules by setting the [LiveView](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V5/liveveiw-liveviewmanager-V5#section411410371767) struct.

## Constraints

1. The sample app is only supported on Huawei phones and tablets with standard systems.
2. The HarmonyOS version must be HarmonyOS 6.0.0 Release or later.
3. The DevEco Studio version must be DevEco Studio 6.0.2 Release or later.
4. The HarmonyOS SDK version must be HarmonyOS 6.0.2 Release SDK or later.
