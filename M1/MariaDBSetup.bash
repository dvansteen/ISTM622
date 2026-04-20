#!/bin/bash
# shebang so the shell knows this is a shell script

set -e # Exit script if error
set -u # Unset variable references cause error -> exit
set -o # Catch pesky |bugs| hiding in pipes

# Log all stdout output to this log file
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
# Politely ask tools not to attempt to run interactively
export DEBIAN_FRONTEND=noninteractive

touch /root/1-script-started

# Standard update package lists and then packages
apt update
apt upgrade -y

touch /root/2-packages-upgraded

# Use curl to grab files from MariaDB website
apt install apt-transport-https curl -y
# Configure the official gpg key from Maria DB Foundation
curl -LsSo /etc/apt/trusted.gpg.d/mariadb-keyring-2025.gpg https://supplychain.mariadb.com/mariadb-keyring-2025.gpg
# Use Maria DB Foundation's official setup script that varifies gpg key and adds the repo
curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

# update package list from mariadb repo
apt update
# install the mariadb-server package from the newly added repo
apt install mariadb-server -y

# MariaDB automatically enables and starts as a 
# part of the Ubuntu package install process

touch /root/3-mariadb-installed

useradd -m -s /bin/bash dvansteenwyk

mariadb <<EOF
CREATE DATABASE POS;
CREATE USER 'dvansteenwyk'@'localhost';
GRANT ALL PRIVILEGES ON POS.* TO 'dvansteenwyk'@'localhost';
FLUSH PRIVILEGES;

EOF

touch /root/4-user-setup

apt install unzip -y
sudo -u dvansteenwyk wget http://622.gomillion.org/data/126009757.zip -O /home/dvansteenwyk/126009757.zip
sudo -u dvansteenwyk unzip /home/dvansteenwyk/126009757.zip -d /home/dvansteenwyk
sudo -u dvansteenwyk cat > /home/dvansteenwyk/etl.sql <<EOF
DROP DATABASE IF EXISTS POS; 
CREATE DATABASE POS; 
USE POS;

CREATE TABLE Customer (
    id SERIAL PRIMARY KEY,
    firstName VARCHAR(32),
    lastName VARCHAR(30),
    email VARCHAR(128),
    address1 VARCHAR(100),
    address2 VARCHAR(50),
    phone VARCHAR(32),
    birthdate DATE,
    zip DECIMAL(5) ZEROFILL
) ENGINE=InnoDB; /* Don't forget to explicitly set engine */

CREATE TABLE City (
    zip DECIMAL(5) ZEROFILL PRIMARY KEY,
    city VARCHAR(32),
    \`state\` VARCHAR(4)
) ENGINE=InnoDB;

CREATE TABLE \`Order\` (
    id SERIAL PRIMARY KEY,
    datePlaced DATE,
    dateShipped DATE,
    customer_id BIGINT UNSIGNED
) ENGINE=InnoDB;

CREATE TABLE Orderline (
    order_id BIGINT UNSIGNED NOT NULL,
    product_id BIGINT UNSIGNED NOT NULL,
    quantity INTEGER,
    PRIMARY KEY (order_id, product_id)
) ENGINE=InnoDB;

CREATE TABLE Product (
    id SERIAL PRIMARY KEY,
    name VARCHAR(128),
    currentPrice DECIMAL(6,2), 
    availableQuantity INTEGER
) ENGINE=InnoDB;

CREATE TABLE PriceHistory (
    id SERIAL PRIMARY KEY,
    oldPrice DECIMAL(6,2),
    newPrice DECIMAL(6,2),
    ts TIMESTAMP,
    product_id BIGINT UNSIGNED
) ENGINE=InnoDB;


/* Avoid defining FKs in CREATE because this is less painful */
ALTER TABLE Customer ADD CONSTRAINT FK_Customer_City_zip 
    FOREIGN KEY (\`zip\`)
    REFERENCES \`City\`(\`zip\`);
ALTER TABLE \`Order\` ADD CONSTRAINT FK_Order_Customer_customer_id 
    FOREIGN KEY (\`customer_id\`)
    REFERENCES \`Customer\`(\`id\`);
ALTER TABLE \`Orderline\` ADD CONSTRAINT FK_Orderline_Order_order_id 
    FOREIGN KEY (\`order_id\`)
    REFERENCES \`Order\`(\`id\`);
ALTER TABLE \`Orderline\` ADD CONSTRAINT FK_Orderline_Product_product_id 
    FOREIGN KEY (\`product_id\`)
    REFERENCES \`Product\`(\`id\`);
ALTER TABLE \`PriceHistory\` ADD CONSTRAINT FK_PriceHistory_Product_product_id 
    FOREIGN KEY (\`product_id\`)
    REFERENCES \`Product\`(\`id\`);

/* Create a table for the raw data with types suited for them */
CREATE TABLE CustomerStaging (
    id BIGINT UNSIGNED PRIMARY KEY,
    firstName VARCHAR(32),
    lastName VARCHAR(30),
    city VARCHAR(32),
    \`state\` VARCHAR(4),
    zip VARCHAR(10),
    address1 VARCHAR(100),
    address2 VARCHAR(50),
    email VARCHAR(128),
    birthdate VARCHAR(20)
);

LOAD DATA LOCAL INFILE '/home/dvansteenwyk/customers.csv'
    INTO TABLE CustomerStaging FIELDS TERMINATED BY ','
	    OPTIONALLY ENCLOSED BY '"'
    IGNORE 1 LINES;
/* Use a select to transform the data as it is more readable than load data substitutions */
INSERT INTO City (
    SELECT CAST(zip AS DECIMAL(5)), 
            TRIM('"' FROM city), 
            \`state\`
        FROM CustomerStaging
        GROUP BY zip
);
INSERT INTO Customer (
    SELECT id, 
            TRIM('"' FROM firstName), 
            TRIM('"' FROM lastName),
            NULLIF(email, ''),
            TRIM('"' FROM address1),
            NULLIF(TRIM('"' FROM address2), ''),
            NULL,
            STR_TO_DATE(birthdate, '%m/%d/%Y'),
            CAST(zip AS DECIMAL(5))
        FROM CustomerStaging
);

DROP TABLE CustomerStaging; /* Done with it */

/* Create a table for the raw data with types suited for them */
CREATE TABLE OrderStaging (
    id BIGINT UNSIGNED,
    customer_id BIGINT UNSIGNED,
    datePlaced VARCHAR(30),
    dateShipped VARCHAR(30)
);
LOAD DATA LOCAL INFILE '/home/dvansteenwyk/orders.csv'
    INTO TABLE OrderStaging FIELDS TERMINATED BY ','
	    OPTIONALLY ENCLOSED BY '"'
    IGNORE 1 LINES
;
/* Use a select to transform the data as it is more readable than load data substitutions */
INSERT INTO \`Order\` (
    SELECT id, 
            STR_TO_DATE(TRIM('"' FROM datePlaced), '%Y-%m-%d %T'),
            STR_TO_DATE(NULLIF(TRIM('"' FROM dateShipped), 'Cancelled'), '%Y-%m-%d %T'),
            customer_id
        FROM OrderStaging
);

DROP TABLE OrderStaging;

/* Create a table for the raw data with types suited for them */
CREATE TABLE ProductStaging (
    id BIGINT UNSIGNED,
    name VARCHAR(100),
    price VARCHAR(30),
    quantity INTEGER
);
LOAD DATA LOCAL INFILE '/home/dvansteenwyk/products.csv'
    INTO TABLE ProductStaging 
	FIELDS TERMINATED BY ','
	    OPTIONALLY ENCLOSED BY '"'
    IGNORE 1 LINES
;
/* Use a select to transform the data as it is more readable than load data substitutions */
INSERT INTO Product (
    SELECT id, 
            TRIM('"' FROM name),
            /* replace '$', ',', and '"' with empty string */
            CAST(REGEXP_REPLACE(price, '[$,"]', '') AS DECIMAL(6,2)),
            quantity
        FROM ProductStaging
);
INSERT INTO PriceHistory (oldPrice, newPrice, ts, product_id) (
    SELECT NULL,
            /* replace '$', ',', and '"' with empty string */
            CAST(REGEXP_REPLACE(price, '[$,"]', '') AS DECIMAL(6,2)),
            NOW(), /* No data given so this is the 'new' official price as of NOW */
            id
        FROM ProductStaging
);

DROP TABLE ProductStaging;

/* Create a table for the raw data with types suited for them */
CREATE TABLE OrderlineStaging (
    order_id BIGINT UNSIGNED,
    product_id BIGINT UNSIGNED
);
LOAD DATA LOCAL INFILE '/home/dvansteenwyk/orderlines.csv'
    INTO TABLE OrderlineStaging FIELDS TERMINATED BY ','
	    OPTIONALLY ENCLOSED BY '"'
    IGNORE 1 LINES
;
/* Use a select to transform the data as it is more readable than load data substitutions */
INSERT INTO Orderline (
    SELECT order_id, 
            product_id,
            COUNT(*)
        FROM OrderlineStaging
        GROUP BY order_id, product_id
);

DROP TABLE OrderlineStaging;
EOF
chown dvansteenwyk:dvansteenwyk /home/dvansteenwyk/etl.sql
chmod 755 /home/dvansteenwyk/etl.sql
sudo -u dvansteenwyk cat /home/dvansteenwyk/etl.sql | mariadb -u dvansteenwyk

touch /root/5-etl-done