# Privacy

PhotoCraft Bridge reads the image fill selected by the user in Figma or Adobe XD. It passes that image to a local companion, creates a PSD working file, opens it in PhotoCraft, reads its saved composite, and returns the result to the associated layer.

## Information processed

- Selected image bytes and edited composite images.
- Local PSD working files and source images.
- Layer identifiers, image hashes, editing-job identifiers, and local file paths needed to associate a saved image with its layer.
- A randomly generated local authentication token. The token is not embedded in public release packages or stored in a Figma design document.

The public Figma build uses a new document-session identifier for each plugin run. It does not use Figma's private file-key API.

## Where data goes

The plugin and companion communicate over HTTP on the computer's loopback interface. The HTTP channel is authenticated with the installation token; it is not TLS. The companion does not bind a public network interface, send images to an external editing service, or collect analytics or telemetry.

Figma and Adobe XD may sync the edited design document through their own cloud services. Their services and PhotoCraft's separate features are governed by their respective privacy policies.

## Local storage and retention

- Figma companion configuration and working PSDs: `~/Library/Application Support/Figma-PhotoCraft/`.
- XD companion configuration: `~/Library/Application Support/XD-Compositor/`.
- XD working images and PSDs: the host-managed `CmptXd01` plugin data directory under `~/Library/Application Support/Adobe/UXP/PluginsStorage/SPRK/`.
- Companion applications: `~/Applications/`.
- User login agents: `~/Library/LaunchAgents/`.

Companion configuration files are written with owner-only permissions. PSDs and source images remain on disk so the user can continue editing them. Obsolete generated PNG results are removed after acknowledged delivery, subject to retaining pending versions.

Removing a companion does not automatically erase working PSDs. To delete them, close their editor documents and remove the corresponding project folders. To revoke a token, stop the companion and remove its configuration; a subsequent installation generates a new token. Remove the plugin's stored pairing data before pairing it again. Deleting a configuration file alone does not change the token already held by a running companion. Treat pairing codes as local credentials and do not publish them.

## Permissions

The Figma companion handles files and launches PhotoCraft. Figma document changes are made by the official Plugin API. It does not inject code into or modify the Figma application.

The XD companion uses macOS Accessibility access to invoke XD's plugin update menu. The user grants or revokes this in System Settings. The normal installer does not change XD's application bundle.

## Contact

Report privacy or data-handling questions through this repository's Issues page. Avoid posting private files or tokens in a public report.
