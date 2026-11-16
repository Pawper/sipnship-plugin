Instructions: Set up the sensor hub for the herb beds

This lets the frost alert reach your phone before a cold night. Only you can do it, because the secret belongs to your repository and the hub runs on your rooftop network.

1. Add a repository secret named `FROST_SENDER_KEY` in your repository's settings, under Secrets, so the alert may send messages for you.
2. Install the hub on the rooftop network by running this in a terminal in your project folder, which connects the soil sensors to the alert:

```
npx sensor-hub install --bed herbs
```

3. To tell it worked, open the herb bed page: the hub shows as connected within a minute.
