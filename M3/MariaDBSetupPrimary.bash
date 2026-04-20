#!/bin/bash
# shebang so the shell knows this is a shell script
# use tail -f /var/log/user-data.log | grep "mariadb" to check mariadb status
# use tail -f /var/log/user-data.log | grep -m 1 "SUCCESS" if you are confident

set -e # Exit script if error
set -u # Unset variable references cause error -> exit
set -o # Catch pesky |bugs| hiding in pipes

# CHANGE THESE AFTER THE PRIMARY STARTS
SERVERID="1"
HOSTADDR="localhost"

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
curl -LsSo /etc/apt/trusted.gpg.d/mariadb-keyring-2025.gpg \
    https://supplychain.mariadb.com/mariadb-keyring-2025.gpg
# Use Maria DB Foundation's official setup script that varifies gpg key 
# and adds the repo
curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
    > mariadb_repo_setup
# Official checksum verification and exit script on fail
checksum="73f4ab14ccc3ceb8c03bb283dd131a3235cfc28086475f43e9291d2060d48c97"
echo "${checksum} mariadb_repo_setup" | sha256sum -c -
cat mariadb_repo_setup | bash

# update package list from mariadb repo
apt update
# install the mariadb-server package from the newly added repo
apt install mariadb-server -y

# MariaDB automatically enables and starts as a 
# part of the Ubuntu package install process

touch /root/3-mariadb-installed

HOSTADDR="$( hostname -I | awk '{print $1}' )"
MYADDR="%"

USERNAME="dvansteenwyk"
REPLUSER="repluser"
PASSWORD="notthepassword"
REPLPASS="guessagain"
REPLPORT="3306"
MONITORCMD=\
"mariadb -e 'SHOW REPLICA HOSTS;' | \
grep -P '\| ${REPLPORT} \|' | wc -l"

# Set up a dedicated replication user for mariadb
useradd -m -p ${REPLPASS} -s /bin/bash ${REPLUSER}

mariadb <<EOF
CREATE USER '${REPLUSER}'@'${MYADDR}' IDENTIFIED BY '${REPLPASS}';
GRANT REPLICATION SLAVE ON *.* TO '${REPLUSER}'@'${MYADDR}';
FLUSH PRIVILEGES;

EOF

# Change configuration file to set host address and server id
# In version 12.2, mariadb no longer uses skip-networking and instead uses a
# default bind address of 127.0.0.1 to disable connections
sed -i "s/127.0.0.1/${HOSTADDR}/" /etc/mysql/mariadb.conf.d/50-server.cnf
# Uncomment configs if commented
sed -i "s/^#*\(server-id[[:space:]]*= \)\([0-9]*\)/\1${SERVERID}/" \
/etc/mysql/mariadb.conf.d/50-server.cnf
sed -i "s/^#*\(log_bin.*\)/\1/" /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mariadb

# Wait for both repicas to connect
until [ "$( mariadb -e 'SHOW REPLICA HOSTS;' | \
grep -P '| ${REPLPORT} |' | \
wc -l )" = "2" ]; do
    echo "Waiting for 2 replica connections..."
    sleep 5
done
echo "2 replicas connected"

useradd -m -p ${PASSWORD} -s /bin/bash ${USERNAME}

mariadb <<EOF
CREATE DATABASE POS;
CREATE USER '${USERNAME}'@'localhost' IDENTIFIED BY '${PASSWORD}';
GRANT ALL PRIVILEGES ON POS.* TO '${USERNAME}'@'localhost';
FLUSH PRIVILEGES;

EOF

touch /root/4-replication

apt install unzip -y
sudo -u ${USERNAME} wget http://622.gomillion.org/data/126009757.zip -O \
    /home/${USERNAME}/126009757.zip
sudo -u ${USERNAME} unzip /home/${USERNAME}/126009757.zip -d /home/${USERNAME}
sudo -u ${USERNAME} cat > /home/${USERNAME}/etl.sql <<EOF
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

LOAD DATA LOCAL INFILE '/home/${USERNAME}/customers.csv'
    INTO TABLE CustomerStaging FIELDS TERMINATED BY ','
        OPTIONALLY ENCLOSED BY '"'
    IGNORE 1 LINES;
/* Use a select to transform the data as it is more readable 
   than load data substitutions */
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
LOAD DATA LOCAL INFILE '/home/${USERNAME}/orders.csv'
    INTO TABLE OrderStaging FIELDS TERMINATED BY ','
        OPTIONALLY ENCLOSED BY '"'
    IGNORE 1 LINES
;
/* Use a select to transform the data as it is more readable than 
   load data substitutions */
INSERT INTO \`Order\` (
    SELECT id, 
            STR_TO_DATE(TRIM('"' FROM datePlaced), '%Y-%m-%d %T'),
            STR_TO_DATE(NULLIF(TRIM('"' FROM dateShipped), 'Cancelled'),
                '%Y-%m-%d %T'),
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
LOAD DATA LOCAL INFILE '/home/${USERNAME}/products.csv'
    INTO TABLE ProductStaging 
    FIELDS TERMINATED BY ','
        OPTIONALLY ENCLOSED BY '"'
    IGNORE 1 LINES
;
/* Use a select to transform the data as it is more readable 
   than load data substitutions */
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
            /* No data given so this is the 'new' official price as of NOW */
            NOW(), 
            id
        FROM ProductStaging
);

DROP TABLE ProductStaging;

/* Create a table for the raw data with types suited for them */
CREATE TABLE OrderlineStaging (
    order_id BIGINT UNSIGNED,
    product_id BIGINT UNSIGNED
);
LOAD DATA LOCAL INFILE '/home/${USERNAME}/orderlines.csv'
    INTO TABLE OrderlineStaging FIELDS TERMINATED BY ','
        OPTIONALLY ENCLOSED BY '"'
    IGNORE 1 LINES
;
/* Use a select to transform the data as it is more readable 
   than load data substitutions */
INSERT INTO Orderline (
    SELECT order_id, 
            product_id,
            COUNT(*)
        FROM OrderlineStaging
        GROUP BY order_id, product_id
);

DROP TABLE OrderlineStaging;
EOF

sudo -u ${USERNAME} cat > /home/${USERNAME}/views.sql <<EOF
SOURCE /home/${USERNAME}/etl.sql

USE POS;

-- Handy view that will be used once ever
CREATE OR REPLACE VIEW v_ProductBuyers
    AS SELECT P.id productID, P.name productName, 
            GROUP_CONCAT(
                DISTINCT CONCAT(C.id, ' ', C.firstName, ' ', C.lastName)
                ORDER BY C.id
                SEPARATOR ','
            ) customers
        FROM Customer C
        JOIN \`Order\` O ON O.customer_id = C.id
        JOIN Orderline OL ON OL.order_id = O.id
        -- Could benchmark this against an initial left join
        RIGHT JOIN Product P ON P.id = OL.product_id
        GROUP BY P.id, P.name
        ORDER BY P.id
;

-- Here it is, the single use of the view to create an MV table
CREATE TABLE IF NOT EXISTS mv_ProductBuyers ENGINE=InnoDB
    AS SELECT * FROM v_ProductBuyers
;

-- Boost performance by indexing the id
CREATE INDEX IF NOT EXISTS i_mv_ProductBuyers__productID
    ON mv_ProductBuyers (productID)
;

-- Prepare for code blocks
DELIMITER ||

-- Create procedure for shared update logic
CREATE OR REPLACE PROCEDURE p_update_customer_list(
    IN target_product_id BIGINT
)
BEGIN
    -- Refresh the list of customers that have ordered product
    UPDATE mv_ProductBuyers
        SET customers = (
            SELECT GROUP_CONCAT(
                DISTINCT CONCAT(C.id, ' ', 
                    C.firstName, ' ', C.lastName
                )
                ORDER BY C.id
                SEPARATOR ','
            )
            FROM \`Order\` O
            JOIN (
                SELECT DISTINCT OL.order_id id FROM Orderline OL
                    WHERE OL.product_id = target_product_id
            ) PO ON PO.id = O.id
            -- At this point we have all product's orders
            JOIN Customer C ON C.id = O.customer_id
        )
        WHERE productID = target_product_id
    ;
END ||

-- Add triggers for both insert and delete to update mv_ProductBuyers
-- using p_update_customer_list
CREATE OR REPLACE TRIGGER t_mv_ProductBuyers__Orderline_insert
    AFTER INSERT ON Orderline
        FOR EACH ROW
        BEGIN
            CALL p_update_customer_list(NEW.product_id);
        END;
        ||
        
CREATE OR REPLACE TRIGGER t_mv_ProductBuyers__Orderline_delete
    AFTER DELETE ON Orderline
        FOR EACH ROW
        BEGIN
            CALL p_update_customer_list(OLD.product_id);
        END;
        ||

-- Only update price history when product price changes
CREATE OR REPLACE TRIGGER t_PriceHistory__Product_update
    AFTER UPDATE ON Product
        FOR EACH ROW
        BEGIN
            IF OLD.currentPrice != NEW.currentPrice THEN
                INSERT INTO PriceHistory(oldPrice, newPrice, ts, product_id) 
                    VALUES(OLD.currentPrice, NEW.currentPrice, NOW(), OLD.id)
                ;
            END IF;
        END;
        ||

-- Done with code blocks
DELIMITER ;

-- Verify creation success
SHOW CREATE VIEW v_ProductBuyers;
SHOW CREATE TABLE mv_ProductBuyers;
SELECT * FROM mv_ProductBuyers LIMIT 5;

-- Prove price history updates only when it is supposed to
SELECT * FROM PriceHistory WHERE product_id = 3;
UPDATE Product SET currentPrice = currentPrice + 10.00 WHERE id = 3;
SELECT * FROM PriceHistory WHERE product_id = 3;
UPDATE Product SET availableQuantity = 0 WHERE id = 3;
SELECT * FROM PriceHistory WHERE product_id = 3;

-- Prove the MV updates eagerly when order lines are added/removed
SELECT * FROM mv_ProductBuyers WHERE productID = 3;
INSERT INTO Orderline VALUES (1,3,1);
SELECT * FROM mv_ProductBuyers WHERE productID = 3;
DELETE FROM Orderline WHERE order_id = 1 AND product_id = 3;
SELECT * FROM mv_ProductBuyers WHERE productID = 3;

-- For running on Primary
--SHOW MASTER STATUS\\G
--SELECT COUNT(*) FROM Orderline;
--INSERT INTO Orderline VALUES (1,3,1);

-- Run on secondary
--SHOW REPLICA STATUS\\G
--SELECT COUNT(*) FROM Orderline;
--SELECT CURRENT_USER();
--INSERT INTO Orderline VALUES (1,4,1);
EOF

chown ${USERNAME}:${USERNAME} /home/${USERNAME}/etl.sql
chmod 755 /home/${USERNAME}/etl.sql
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/views.sql
chmod 755 /home/${USERNAME}/views.sql
mariadb -e "SET GLOBAL log_bin_trust_function_creators = 1;"
sudo -u ${USERNAME} cat /home/${USERNAME}/views.sql \
    | sudo -u ${USERNAME} mariadb -u ${USERNAME} --password=${PASSWORD}
mariadb -e "SET GLOBAL log_bin_trust_function_creators = 0;"

touch /root/5-etl-done
echo "SUCCESS"