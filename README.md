# Minepanda

A food delivery service for [CC: Tweaked](https://tweaked.cc/) (Fabric). Restaurants run the server on an Advanced Computer; customers order from an Advanced Pocket Computer.

## What you need

| Role | Hardware |
| --- | --- |
| Restaurant | Advanced Computer + Wireless or Ender Modem, and a noteblock next to it |
| Customer | Advanced Pocket Computer with a Wireless or Ender Modem upgrade |

Wireless modems have limited range. Ender modems work anywhere, even across dimensions. If your world has a GPS cluster, orders include the customer's coordinates.

## Install

Run this on each computer. It asks whether the computer is a server or a client, and makes Minepanda start on boot:

```
wget run https://raw.githubusercontent.com/tamayaren/Minepanda/main/install.lua
```

You can skip the question with `... install.lua server` or `... install.lua client`. Run the same command again to update; saved menus and orders are kept.

### Client on a community OS

The client also comes as one self-contained file, [`dist/minepanda.lua`](dist/minepanda.lua), for operating systems that install apps their own way:

```
wget https://raw.githubusercontent.com/tamayaren/Minepanda/main/dist/minepanda.lua
```

Put it wherever the OS keeps apps and start it with the OS's launcher or autostart. It doesn't depend on the CraftOS shell's `require`, keeps its data next to itself (`/apps/minepanda.lua` saves to `/apps/data/minepanda.db`), and starts rednet's background service itself if the OS doesn't. It's laid out for the 26×20 pocket screen, so give it a window at least that big.

The server is only available through the installer above.

## Restaurant (server)

On first start you name the restaurant. The name becomes the computer's label, and no two restaurants can share one.

- **Orders**: new orders appear under *Pending*, oldest first, with the customer's name, computer ID, items, total and location. Click **Delivered** once the food has arrived, or **Reject** if you can't make it. The customer's pocket computer is told either way. *Done* keeps the last 100 finished orders.
- **Menu**: **+ Add item**, then set a name and a price in any mix of Diamond, Emerald, Gold and Iron. Leave every amount at 0 for a free item. Click a number to type it, or right-click **-**/**+** to change it by 10.
- **Config**: rename the restaurant, open or close for orders, choose which side the noteblock is on, set the pulse interval, test the alert and clear the history.

Every new order sends 3 redstone pulses out of the chosen side, so a noteblock there plays 3 times.

## Customer (client)

- **Shops**: tap **Search** to find restaurants in range, then tap one to see its menu. Use **Add**, **-** and **+** to fill the cart, then **Order**.
- **Orders**: every order you've placed, with its status. Pending orders update by themselves when the restaurant marks them delivered or rejected, and you can cancel one while it's pending. You can have several orders open at once, at one restaurant or many.
- **Me**: the name restaurants see, and whether to send your GPS location.

Payment happens in person: the courier collects the price shown on delivery.

## Files

```
install.lua            Installer
minepanda/server.lua   Restaurant program
minepanda/client.lua   Customer program
minepanda/lib/ui.lua   Shared clickable UI toolkit
minepanda/lib/common.lua  Shared protocol, prices and storage
dist/minepanda.lua     Single-file client, generated
tools/bundle-client.js Builds dist/minepanda.lua
```

Data is saved in `/minepanda/data/` on each computer.

`dist/minepanda.lua` is generated, so don't edit it by hand. After changing the client or its libraries, rebuild it with [Node.js](https://nodejs.org/) and commit the result:

```bash
node tools/bundle-client.js
```
