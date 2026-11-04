# Rail

Rail is a personal macOS browser organised around one developer's Spaces, sessions and projects. This glossary covers the language of following work in progress across those projects.

## Language

**Check**:
One required step on the way to merging a pull request, such as a build or status check.
_Avoid_: Job, test

**Tracked Run**:
One unit of work Rail follows from start to finish: all the Checks of one of the user's own open pull requests, or a pipeline run the user started themselves on any branch. It is one entry however many Checks it contains. Other people's runs are never Tracked Runs.
_Avoid_: Notification, entry, watch

**Capsule**:
The single toolbar control that shows how many Tracked Runs are running, waiting for approval, failed or passed, across all Spaces.
_Avoid_: Notification center, inbox, badge

**Announcement**:
The Capsule briefly stating what just happened to a Tracked Run. A failed Tracked Run announces at its first failing Check; a passed one only once all its Checks have finished.
_Avoid_: Toast, alert, notification

**Acknowledge**:
To clear a failed Tracked Run from the Capsule's failed state by dismissing it, opening its run or showing it in Activity. A newer run replacing it has the same effect. Acknowledging changes nothing about the real status shown in Activity and Projects.
_Avoid_: Read, resolve, fix
