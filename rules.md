# Claude review rules

The Claude review reads this file on each run and follows each rule. Edit it on this branch to add, change or remove a rule. The review adds a rule here when the pull request author or the owner says yes to a rule that it proposes.

- Keep UI labels exactly as the product or the platform shows them, also the spaces and the capital letters in inline code. Example: **Inside`<head>`tag** in the Kirki guide matches the Kirki editor. (PR #43)
- "MuconSA Customer Support" is a made-up company name for the tutorials. Do not flag it. (PR #52)
- When the pull request description links a companion code pull request, check the claims against that pull request, not only against the current app code. (PR #67, PR #68)
- Spell these platform names as shown: "ZOHO Sites", "Webstarts". (PR #73)
- Put each platform guide in the docs.json group that matches what the platform is: Website Builders, App Builders, E-commerce, CMS Platforms, LMS Platforms, or Communication & Messaging. Zite is an app builder. (PR #40)
- Keep the pages in each platform group of docs.json in alphabetical order. (PR #57, PR #58)
