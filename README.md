# postgres-release
---

This is a [BOSH](https://www.bosh.io) release for [PostgreSQL](https://www.postgresql.org/).

## Contents

* [Deploying](#deploying)
* [Customizing](#customizing)
* [Contributing](#contributing)
* [Known Limitation](#known-limitation)
* [Upgrading](#upgrading)
* [CI](#ci)

## Deploying

In order to deploy the postgres-release you must follow the standard steps for deploying software with BOSH.

1. Deploy and run a BOSH director.
   Please refer to [BOSH documentation](http://bosh.io/docs) for instructions on how to do that.
   Bosh-lite specific instructions can be found [here](https://github.com/cloudfoundry/bosh-lite).

1. Install the BOSH command line Interface (CLI) v2+.
   Please refer to [BOSH CLI documentation](https://bosh.io/docs/cli-v2.html#install). Use the CLI to target your director.

1. Upload the desired stemcell directly to bosh. [bosh.io](http://bosh.io/stemcells) provides a resource to find and download stemcells.

   ```
   # Example for bosh-lite
   bosh upload-stemcell https://bosh.io/d/stemcells/bosh-warden-boshlite-ubuntu-xenial-go_agent
   ```

1. Upload the latest release from [bosh.io](http://bosh.io/releases/github.com/cloudfoundry/postgres-release?all=1):

   ```
   bosh upload-release https://bosh.io/d/github.com/cloudfoundry/postgres-release
   ```

   or create and upload a development release:

   ```
   cd ~/workspace/postgres-release
   bosh -n create-release --force && bosh -n upload-release
   ```

1. Generate the manifest. You can provide in input an [operation file](https://bosh.io/docs/cli-ops-files.html) to customize the manifest:

   ```
   ~/workspace/postgres-release/scripts/generate-deployment-manifest \
   -o OPERATION-FILE-PATH > OUTPUT_MANIFEST_PATH
   ```

   You can use the operation file to specify `postgres` job properties or to override the configuration if your BOSH director [cloud-config](http://bosh.io/docs/cloud-config.html) is not compatible.

   [This example operation file](templates/operations/set_properties.yml) is a great starting point.
   Note: when using this operation file, you will need to inject `pgadmin_database_password` at `bosh deploy`-time, which is a good pattern for keeping credentials out of manifests.

   You are also provided with options to enable TLS in the PostgreSQL server or to use static ips.

1. Deploy:

   ```
   bosh -d DEPLOYMENT_NAME deploy OUTPUT_MANIFEST_PATH
   ```

   Example, injecting the `pgadmin_database_password` variable:

   ```
   bosh -d DEPLOYMENT_NAME deploy -v pgadmin_database_password=foobarbaz OUTPUT_MANIFEST_PATH
   ```

## Customizing

The table below shows the most significant properties you can use to customize your PostgreSQL installation.
The complete list of available properties can be found in the [spec](jobs/postgres/spec).

Property | Description
-------- | -------------
databases.version | Define the used PostgreSQL major version. Default: 16
databases.port | The database port. Default: 5432
databases.databases | A list of databases and associated properties to create when Postgres starts
databases.databases[n].name | Database name
databases.databases[n].citext | If `true` the citext extension is created for the db
databases.roles | A list of database roles and associated properties to create
databases.roles[n].name | Role name
databases.roles[n].password | Login password for the role. If not provided, TLS certificate authentication is assumed for the user.
databases.roles[n].common_name| The cn attribute of the certificate for the user. It only applies to TLS certificate authentication.
databases.roles[n].permissions| A list of attributes for the role. For the complete list of attributes, refer to [ALTER ROLE command options](https://www.postgresql.org/docs/9.4/static/sql-alterrole.html).
databases.tls.certificate | PEM-encoded certificate for secure TLS communication
databases.tls.private_key | PEM-encoded key for secure TLS communication
databases.tls.ca | PEM-encoded certification authority for secure TLS communication. Only needed to let users authenticate with TLS certificate.
databases.max_connections | Maximum number of database connections
databases.log_line\_prefix | The postgres `printf` style string that is output at the beginning of each log line. Default: `%m:`
databases.collect_statement\_statistics | Enable the `pg_stat_statements` extension and collect statement execution statistics. Default: `false`
databases.additional_config | A map of additional key/value pairs to include as extra configuration properties in `postgresql.conf`
databases.monit_timeout | Monit timout in seconds for the postgres job start. Default: `90`.
databases.trust_local_connection | Whether or not postgres must trust local connections. `vcap` is always trusted. It defaults to `true`.
databases.skip_data_copy_in_minor | Whether or not a copy of the data directory is created during PostgreSQL minor upgrades. A copy is created by default.
databases.hooks.timeout | Time limit in seconds for the hook script. By default, it's set to `0` that means no time limit.
databases.hooks.pre-start | Script to run before starting PostgreSQL.
databases.hooks.post-start | Script to run after PostgreSQL has started.
databases.hooks.pre-stop | Script to run before stopping PostgreSQL.
databases.hooks.post-stop | Script to run after PostgreSQL has stopped.
databases.logging.format.timestamp | Format for timestamp in control jobs logs. By default it's set to `rfc3339`.
janitor.script | If specified, this script would be run periodically. This would be useful for running house-keeping tasks.
janitor.interval | Interval in seconds between two invocations of the janitor script. By default it's set to `1` day.
janitor.timeout | Time limit in seconds for the janitor script. By default it's set to `0` that means no time limit.

*Note*
- Removing a database from `databases.databases` list and deploying again does not trigger a physical deletion of the database in PostgreSQL.
- Removing a role from `databases.roles` list and deploying again does not trigger a physical deletion of the role in PostgreSQL.

### Enabling TLS on the PostgreSQL server
PostgreSQL has native support for using TLS connections to encrypt client/server communications for increased security.
You can enable it by setting the `databases.tls.certificate` and the `databases.tls.private_key` properties.

A script is provided that creates a CA, generates a key pair, and signs it with the CA:

```
./scripts/generate-postgres-certs -n HOSTNAME_OR_IP_ADDRESS
```
 The common name for the server certificate must be set to the DNS hostname if any or to the ip address of the PostgreSQL server. This because in TLS mode `verify-full`, the hostname is matched against the common-name. Refer to [PostgreSQL documentation](https://www.postgresql.org/docs/9.6/static/libpq-ssl.html) for more details.

 You can also use [BOSH variables](https://bosh.io/docs/cli-int.html) to generate the certificates. See by way of [example](templates/operations/use_ssl.yml) the operation file used by the manifest generation script.

```
~/workspace/postgres-release/scripts/generate-deployment-manifest \
   -s -h HOSTNAME_OR_IP_ADDRESS \
   -o OPERATION-FILE-PATH > OUTPUT_MANIFEST_PATH

```
### Enabling TLS certificate authentication

In order to perform authentication using TLS client certificates, you must not specify a user password and you must configure the following properties:

- `databases.tls.certificate`
- `databases.tls.private_key`
- `databases.tls.ca`

The cn (Common Name) attribute of the certificate will be compared to the requested database user name, and if they match the login will be allowed.

Optionally you can map the common_name to a different database user by specifying property `databases.roles[n].common_name`.

A script is provided that creates a client certificates:

```
./scripts/generate-postgres-client-certs --ca-cert <PATH-TO-CA-CERT> --ca-key <PATH-TO-CA-KEY> --client-name <USER_NAME>
```

### Hooks
You can run custom code before or after PostgreSQL starts or stops or periodically.
For details, see [hooks](docs/hooks.md) documentation.

### Backup and Restore
You can enable backup and restore through bbr by adding the `bbr-postgres-db` job with the `postgres` job and by setting its `release_level_backup` option to `true`. If enabled, a backup is collected using `pg_dump` for each database specified in the `databases.databases` property.

If you don't colocate the `bbr-postgres-db` with `postgres` then you must specify in the `postgres.dbuser` property a database user with enough permissions to run backup and restore.

If your PostgreSQL is configured with TLS, by default backup and restore are run with `sslmode=verify-full`. You can change it to `sslmode=verify-ca` by setting `postgres.ssl_verify_hostname` to `false`.

Caveats:

- Restore does not drop the database, the extensions, or the schema; therefore the schema of the restored and existing databases must be the same.
- If a backup is not present for one of the configured databases in the `databases.databases` property, the restore issues a message and continues.

## Contributing

### Contributor License Agreement

Contributors must sign the Contributor License Agreement before their contributions can be merged.
Follow the directions [here](https://www.cloudfoundry.org/community/contribute/) to complete that process.

### Developer Workflow

1. [Fork](https://help.github.com/articles/fork-a-repo) the repository and make a local [clone](https://help.github.com/articles/fork-a-repo#step-2-create-a-local-clone-of-your-fork)
1. Create a feature branch from the development branch

   ```bash
   cd postgres-release
   git checkout develop
   git checkout -b feature-branch
   ```
1. Make changes on your branch
1. Test your changes by running [acceptance tests](docs/acceptance-tests.md)
1. Push to your fork (`git push origin feature-branch`) and [submit a pull request](https://help.github.com/articles/creating-a-pull-request) selecting `develop` as the target branch.
   PRs submitted against other branches will need to be resubmitted with the correct branch targeted.

## Known Limitations

The postgres-release does not directly support high availability.
Even if you deploy more instances, no replication is configured.

## Upgrading

Refer to [versions.yml](versions.yml) in order to assess if a postgres-release version upgrades the PostgreSQL version.

### Upgrade Test Policy

The maintainers of the postgres-release test the following upgrade paths:

* From the previous postgres-release
* From the latest postgres-release that bumps the previous PostgreSQL version
* From the latest cf-deployment that bumps the previous PostgreSQL version

### Considerations before deploying

1. A copy of the database is made for the upgrade, you may need to adjust the persistent disk capacity of the `postgres` job.
    - For major upgrades the copy is always created
    - For minor upgrades the copy is created unless the `databases.skip_data_copy_in_minor` is set to `true`.
1. The upgrade happens as part of the pre-start and its duration may vary basing on your env.
    - In case of a PostgreSQL minor upgrade a simple copy of the old data directory is made.
    - In case of a PostgreSQL major upgrade the `pg_upgrade` utility is used.
1. Postgres will be unavailable during this upgrade.

### Considerations after a successful deployment

PostgreSQL upgrade may require some post-upgrade processing. The administrator should check the `/var/vcap/store/postgres/pg_upgrade_tmp` directory for the generated script files and eventually run them. See [pg_upgrade post-upgrade processing](https://www.postgresql.org/docs/11/pgupgrade.html) for more details.

In case a copy of the old database is kept (see considerations above), the old database is moved to `/var/vcap/store/postgres/postgres-previous`. The postgres-previous directory will be kept until the next postgres upgrade is performed in the future. You are free to remove this if you have verified the new database works and you want to reclaim the space.

### Recovering a failure during deployment

In case of a long upgrade, the deployment may time out; anyway, bosh would not stop the actual upgrade process. In this case you can just wait for the upgrade to complete and, only when postgres is up and running, rerun the bosh deploy.

If the upgrade fails:

- The old data directory is still available at `/var/vcap/store/postgres/postgres-x.x.x` where `x.x.x` is the old PostgreSQL version
- The new data directory is at `/var/vcap/store/postgres/postgres-y.y.y` where `y.y.y` is the new PostgreSQL version
- If the upgrade is a PostgreSQL major upgrade:
  - A marker file is kept at `/var/vcap/store/postgres/POSTGRES_UPGRADE_LOCK` to prevent the upgrade from happening again.
  - `pg_upgrade` logs that may have details of why the migration failed can be found in `/var/vcap/sys/log/postgres/postgres_ctl.log`

If you want to attempt the upgrade again or to roll back to the previous release, you should remove the new data directory and, if present, the marker file.


## CI

The [CI pipeline](https://postgres.ci.cf-app.com/) runs:

- the postgres-release [acceptance tests](docs/acceptance-tests.md)
- the supported [upgrade paths](#upgrade-test-policy)