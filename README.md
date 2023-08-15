# Multichat.cc

A simple projekt that adds a chat interface over rednet protocols

## Usage
### Client
Simply run the `client.lua` file

### Server
For the Server you need to setup you `startup.lua` file like so.
```lua
shell.execute('client.lua', 'update')
shell.execute('client.lua', 'rednet-bot', '<your-protocol>', '<your-bot-program-here>')
```
After that you can simply use `print` for output and
`rednet.receive '<your-protocl>'` for input.
