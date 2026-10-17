<img align="right" width="300px" height="300px"
     title="Size Limit logo" src="https://i.imgur.com/9xdFwQq.png">


[![Crates.io](https://img.shields.io/crates/v/gcsf.svg)](https://crates.io/crates/gcsf)
[![Docs](https://docs.rs/gcsf/badge.svg)](https://docs.rs/gcsf/latest/gcsf/)<br>
[![GitHub Issues](https://img.shields.io/github/issues/harababurel/gcsf.svg)](https://github.com/harababurel/gcsf/issues)
[![Downloads](https://img.shields.io/crates/d/gcsf.svg)](https://crates.io/crates/gcsf)
[![MIT License](https://img.shields.io/crates/l/gcsf.svg)](https://github.com/harababurel/gcsf/blob/master/LICENSE)

GCSF is a virtual filesystem that allows users to mount their Google Drive account locally and interact with it as a regular disk partition. You can find out more in this [paper](https://harababurel.com/thesis.pdf)

The native build is `make`, and the Rust sources are on the tag `legacy-rust`.

### Configuration

GCSF will attempt to create a configuration file in `$XDG_CONFIG_HOME/gcsf/gcsf.toml`, which is usually defined as `$HOME/.config/gcsf/gcsf.toml`. Credentials are stored in the same directory.

#### GCP

1. Visit [console.developers.google.com](https://console.developers.google.com) and create a new project
2. Add the Google Drive API to the project
3. Configure an OAuth consent screen. Verification should not be required. Should be external unless this project is something internal to your GSuite
4. Configure an OAuth2.0 credential. Do not use WEB as the token type if adding `gcsf` to a headless server - you want to be using the `urn:*` URI (note: if using WEB, you'll need to set the accepted domains to include `http://localhost:8081`)
5. Configure GCSF to use the new `client_id`, `client_secret`, and `project_id`. You should have all these values after creating the credential.
6. Configure GCSF `authorize_using_code=True` if configuring for headless servers. If you do this, completing the OAuth flow in a different browser will provide you a code that you can give to GCSF.

Running `gcsf login some_session_name` at this point should show a URL with your `client_id` query parameter.

#### Publishing to GCP app to Production Mode (Optional, important for long-running services)

If you plan to run GCSF as a system service or for extended periods, it is recommended that your Google Cloud project be **in Production mode**, not Testing mode.

Access tokens for apps in Testing mode expire more frequently, which usually triggers a prompt on GCSF to re-authenticate. This can be inconvenient especially when running GCSF as a system service. Publishing the app to Production mode resolves this issue.

**To publish your app:**
1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Navigate to "APIs & Services" → "OAuth consent screen" -> "Audience"
3. Check the "Publishing status" at the top
4. If it says "Testing", click **"Publish App"**
5. Publishing to Production might require app verification. Follow the process in the "Verification centre" section.
6. After publishing, you must re-authenticate:
   ```bash
   gcsf logout your_session_name
   gcsf login your_session_name
   ```

**Note:** Publishing to Production does NOT require Google verification for personal use. Verification is only needed if you're distributing your app to many external users.

You can verify your authentication is working at any time:
```bash
$ gcsf verify your_session_name
Verifying authentication for session 'your_session_name'...
Authentication is valid.
```

### Usage

The first step is to log in to Drive and authorize the application. A name must be provided for the session:

```bash
$ gcsf login some_session_name
Please direct your browser to https://accounts.google.com/o/oauth2/[...] and follow the instructions displayed there.
Successfully logged in. Saved credentials to "$HOME/.config/gcsf/some_session_name"
```

You can also list all existing sessions:

```bash
$ gcsf list
Sessions:
        - personal
        - some_session_name
        - work
```

And then mount one (or more) of them:

```bash
$ gcsf mount /Volumes/gcsf -s some_session_name
INFO  gcsf > Creating and populating file system...
INFO  gcsf > File system created.
INFO  gcsf > Mounting to /Volumes/gcsf
INFO  gcsf > Mounted to /Volumes/gcsf
```

You can now find the contents of your Drive account in `/Volumes/gcsf`:

<p align="left">
  <img src="https://i.imgur.com/jdFIu5Y.png" alt="GCSF ls"
       width="530px" height="165px">
</p>

Using Ranger:
<p align="left">
  <img src="https://i.imgur.com/BuS9BDD.png" alt="GCSF in Ranger"
       width="616px" height="351px">
</p>


Or Thunar:
<p align="left">
  <img src="https://i.imgur.com/9JSDqez.jpg" alt="GCSF in Thunar"
       width="746px" height="176px">
</p>

#### Drive metadata as extended attributes

GCSF exposes Drive metadata of every file and directory as extended attributes:

| Attribute | Contents |
|---|---|
| `user.gcsf.id` | Drive file id, e.g. for use with the Drive API or rclone |
| `user.gcsf.mime_type` | MIME type of the file on Drive |
| `user.gcsf.owner` | Email address of the owner (comma-separated if there are several) |
| `user.gcsf.web_link` | Link for opening the file in a browser |
| `user.gcsf.md5`, `user.gcsf.sha1`, `user.gcsf.sha256` | Checksums Drive computed for the file's content |
| `user.gcsf.revision` | Id of the current content revision; changes whenever the content does |

List them all with `xattr -l /Volumes/gcsf/some_file`.

Drive provides no checksums or revisions for directories and Google Docs, Sheets, Slides, Drawings and Sites, so these have no such attributes. Neither does a file with modifications that have not been flushed to Drive yet.

#### Verifying copied files

The checksums let you verify a copy end to end against Drive, without reading the file through GCSF again:

```bash
$ cp /Volumes/gcsf/backup.zip /tmp/
$ xattr -p user.gcsf.md5 /Volumes/gcsf/backup.zip
9e107d9d372bb6826bd81d3542a419d6
$ md5 -q /tmp/backup.zip
9e107d9d372bb6826bd81d3542a419d6
```

### Why GCSF?
GCSF stands for "Google Conduce Sistem de Fișiere" which translated from Romanian is "Google Drive Filesystem". However [GDFS](https://github.com/robin-thomas/GDFS) already exists so it remains GCSF.

### Contributing

Contributions are welcome. Documentation available on [docs.rs/gcsf](https://docs.rs/gcsf). You can also help by reporting or fixing [issues](https://github.com/harababurel/gcsf/issues).

[![Star History Chart](https://star-history.dera.page/svg?repos=harababurel/gcsf&type=Date)](https://star-history.dera.page/#harababurel/gcsf&Date)
