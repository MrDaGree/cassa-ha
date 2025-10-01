<p align="center">
  <img src="images/icon.png" width="200"/>
</p>

# Homey Assistant

**Homey Assistant** is a bootstrapping Docker tool that converts a **Homey Pro backup** into a fully working **Home Assistant (Supervised)** environment.
It lets you restore your existing Homey Pro setup as a “Homey Assistant” backup image, ready to run with Home Assistant built-in.

---

## How It Works

1. **Backup Input**
   You start with a `.homeyprobackup` file created using the official [Homey USB Tool](https://usb.homey.app/).

2. **Conversion Process**
   Inside the privileged Docker container:
   - The raw Homey OS image is extracted from the backup.
   - New partitions are created and formatted (`/boot` as FAT32, `/` as ext4).
   - The Homey root filesystem is restored while excluding transient directories.
   - Boot configuration files (`cmdline.txt`, `config.txt`, `fstab`) are rewritten to boot properly on the modified image.
   - Ansible is run in a chroot environment to install and configure **Home Assistant Supervised**.

3. **Output**
   The tool writes back a new `.homeyprobackup` file alongside the original, with the same name except `Pro` is replaced with `Assistant`.
   This file can be restored to your Homey using the USB Tool.

---

## Hardware Considerations

- The default **8GB eMMC Compute Module 4 (CM4)** used in most Homey Pro devices *may* work, but space will be very tight once Home Assistant is running.
- It is **strongly recommended** to upgrade your CM4 to a larger storage option (16GB, 32GB) for stability and room to grow.
- Larger modules reduce the risk of running out of space during upgrades, logs, and add-on installations.

---

## Prerequisites

- [USB Tool for Homey Backups/Restores](https://usb.homey.app/)
- A Homey Pro device and USB-C cable
- Docker (with `--privileged` support)

---

## Quick Start

1. **Create a Homey Pro backup**
   Use the [USB Tool](https://usb.homey.app/) to create a backup of your Homey Pro.
   Note where the `.homeyprobackup` file is saved.

2. **Run the converter**
   From the directory where the backup file is stored, run:

   ```bash
   docker run --rm -it --privileged -v "$PWD:/work" ghcr.io/mrdagree/homey-assistant:latest \
     "Homey Pro Backup 2025-09-06T22_47_06.627Z.homeyprobackup"
   ```

    Replace the filename with your actual backup’s name.

3. **Restore the converted backup**
   Use the [USB Tool](https://usb.homey.app/) again, but this time choose **Restore** and select the new file.
   The filename will match your original backup, except `Pro` will be replaced with `Assistant`.

4. **Boot into Homey Assistant**

   * Unplug and replug your Homey Pro (still connected over USB-C).
   * After a few seconds, a serial device should appear.
   * Connect at baud rate `115200`.

5. **Initial login**

   * Username: `homey`
   * Password: `homey`
   * On first login, you’ll be prompted for the sudo password (`homey`) to set up Wi-Fi.

6. **Access Home Assistant**
   Once Wi-Fi is configured, note the IP shown during setup.
   After 5–20 minutes (for initialization), access Home Assistant at:

   ```
   http://<ip-address>:8123
   ```

7. **Recommended post-setup**

   * Configure backups to a network location.
   * Install the [Homey Coprocessor Bridge add-on](https://github.com/MrDaGree/hassio-homey-coprocessor-bridge) for Z-Wave integration.

---

## Notes

* Initialization can take several minutes depending on your device and network speed.
* Always keep an original Homey Pro backup for safety.
* The container must run with `--privileged` to access loop devices and partitions.

## Zigbee (ZHA/Z2M)

To utilize Zigbee on the "Homey Assistant", the setup is straight forward and works natively with the hardwarestack. Below is the settings I utilize for my ZHA setup.

* Radio Type: `ezsp`
* Serial Port: `/dev/ttyZigbeeNCP`
* Baudrate: `115200`

This works as on the Homey Pro, the Zigbee radio is exposed as a UART device right inside the OS. Unfortunately, the Z-Wave radio and other integrations are all behind a ESP32 chip that requires the [Coprocessor Bridge add-on](https://github.com/MrDaGree/hassio-homey-coprocessor-bridge) to unlock this functionality. I only have 1 Z-Wave button device, so I dont have much to test/develop the add-on with. I do plan to add LED integration.]
