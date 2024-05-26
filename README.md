# FaceSaver

> A modern macOS application designed to help you break the habit of touching your face.

FaceSaver is an innovative macOS application designed to help users avoid touching their face while working or relaxing at their computer. By leveraging state-of-the-art machine learning and computer vision technologies, FaceSaver analyzes real-time video from your webcam to detect when you touch your face and plays an alert to remind you to stop.

## Key Features

- **Real-Time Face Touch Detection:** Continuously monitors your webcam feed and alerts you immediately when it detects face touching.
- **Customizable Settings:** Tailor the sensitivity, frame rate, and alert types to suit your preferences.
- **Easy Installation and Use:** Simple setup with no additional dependencies required. The intuitive interface lets you get started quickly.
- **Visual Feedback:** Provides on-screen visual cues showing detection zones and key facial points, helping you understand how the system works.

## Technology Stack

FaceSaver utilizes the following technologies:

- **AVFoundation:** Captures and processes video streams from the webcam.
- **Vision:** Analyzes video frames to detect motion and face touches.
- **CoreML:** Employs a custom-trained machine learning model to accurately identify face touching events.

## Installation and Setup

1. **Installation Steps:**
   - Clone or download the FaceSaver repository.
   - Open the project in Xcode from the `FaceSaver` folder.
   - Build and run the project on your macOS device.

2. **Launching the Application:**
   - Open FaceSaver from your Applications folder or run it directly from Xcode if in development mode.
   - Ensure the application has permission to access your webcam.
   - Customize the sensitivity and alert settings according to your needs.
   - FaceSaver will start monitoring automatically and alert you when it detects face touches.

## Customization

FaceSaver allows you to personalize your experience with various settings:
- **Sensitivity:** Adjust how sensitive the detection should be.
- **Alert Preferences:** Choose the type of alert that works best for you (sound, notification, etc.).
- **Visualization:** View real-time overlays showing detection areas and face landmarks.

## Future Releases

After making some changes, I encountered conflicts that I couldn't resolve. As a result, only the camera function works, while the other features have stopped functioning. However, I aim to fix these issues and release the fully functioning application in the future.

## Contact

For questions, suggestions, or feedback, please reach out to us at [akosya.akmaral@gmail.com].

---

Thank you for using FaceSaver! Together, we can build healthier habits and reduce the risk of spreading germs.
