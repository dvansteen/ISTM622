#!/bin/bash
# TODO make things consistent and pretty
# (This will probably never happen)

# I changed the indent to 2 spaces to meet AWS character limit
# TODO trim whitespace in command line

# config

# CHANGE to your UNAME and password
UNAME="dvansteenwyk"
PASSWORD="notthepassword"
TAMUUID="126009757"

# For discarding pasted text that comes after an error
UNPASTE="echo 'FAILED\n' && cat > /dev/null"

IMAGEID="ami-0ec10929233384c7f"   # Ubuntu server 24.04 LTS
INSTTYPE="t3.micro"
KEYNAME="vockey"
# CHANGE to whatever you want or a groupname you already have
SGNAME="SSHOnly"
SGDESC="A security group for allowing ssh and other galera cluster members"
# Grab Security Group ID from JSON query
SGIDPARSE="SecurityGroups[*].GroupId"
# This is only used for ssh. To make extra secure use your own IP address
MYIP="0.0.0.0/0" # use curl https://checkip.amazonaws.com if running from home
# AWS CLI command to get AccountID in plain text
MYACCT="$(aws sts get-caller-identity --query "Account" --output text)"
# Ports needed for MariaDB
PORTS=("tcp 3306")
# This iam profile will allow us to send remote commands
IAMPROFILE="LabInstanceProfile"
# Update this when a new stable version releases
MARIADBVER="11.8"

# Outfiles for JSON Milestone
OUTFILE_DIR="/var/lib/mysql_files"
PROD_OUT="${OUTFILE_DIR}/prod.json"
CUST_OUT="${OUTFILE_DIR}/cust.json"
CUSTOM1_OUT="${OUTFILE_DIR}/custom1.json"
CUSTOM2_OUT="${OUTFILE_DIR}/custom2.json"


WAIT_TIMEOUT=100 # Default of 'aws ssm wait command-executed' is 100
POLL_INTERVAL=5  # Default of 'aws ssm wait command-executed' is 5
gen_poll_wait() { # $1=POLLCOMM $2=TARGETS $3=WAITMSG
  DURATION=0
  COMMSTATUS=`${1}`
  # Regex for 'while COMMSTATUS NOT IN TARGETS'
  while [[ " ${2}[*] " =~ " ${COMMSTATUS} " && \
        $DURATION -lt $WAIT_TIMEOUT ]]; do
    echo "$3"
    sleep $POLL_INTERVAL
    COMMSTATUS=`${1}`
    let DURATION=DURATION+POLL_INTERVAL
  done
  
  echo "Command finished with status: $COMMSTATUS"

  if [ $? -ne 0 ]; then
    $("${UNPASTE}")
  fi
}

# This is a more versitile version of 'aws ssm wait command-executed'
gci_poll_wait() { #$1=COMMID $2=INSTANCEID $3=WAITMSG
  TERM_STATS=( "Success" "Cancelled" "TimedOut" "Failed" )
  UNTERM_STATS=( "Pending" "InProgress" "Delayed" "Cancelling" )
  POLLCOMM="aws ssm get-command-invocation \
    --command-id $1 \
    --instance-id $2 \
    --query Status \
    --output text"
  gen_poll_wait "$POLLCOMM" UNTERM_STATS "$3" 
}

comm_send_wait() { #$1=INSTANCEID $2=COMMAND $3=WAITMSG $4=RETURN_COMMID
  # Use the variable passed as reference to set COMMID
  # Used for checking for return status after command terminates
  local -n CID=$4
  CID=$( aws ssm send-command \
    --instance-ids "$INSTANCEA" \
    --document-name "AWS-RunShellScript" \
    --parameters \
      "commands=[$2]" \
    --region us-east-1 \
    --query "Command.CommandId" \
    --output text )
  if [ $? -ne 0 ]; then
    $("${UNPASTE}")
  fi
  sleep 1
  gci_poll_wait "$CID" "$1" "$3"
}

# construct IP permissions for a single security group rule
ip_permissions_str() { #$1=SGID $2=PROTOCOL $3=PORT $4=MYUSERID
  echo "IpProtocol=$2,FromPort=$3,ToPort=$3, \
    UserIdGroupPairs=[{UserId=$4,GroupId=$1}]" \
    | tr -d "[:space:]"
}

read -r -d '' STARTUP <<EOF
#!/bin/bash
# shebang so the shell knows this is a shell script
# use tail -f /var/log/user-data.log | grep "mariadb" to check mariadb status
# use tail -f /var/log/user-data.log | grep -m 1 "SUCCESS" if you are confident

set -e # Exit script if error
set -u # Unset variable references cause error -> exit
set -o # Catch pesky |bugs| hiding in pipes

touch /root/0-script-failed

# Log all stdout output to this log file
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
# Politely ask tools not to attempt to run interactively
export DEBIAN_FRONTEND=noninteractive

touch /root/1-script-started

# Standard update package lists and then packages
apt-get update
apt-get upgrade -y

touch /root/2-packages-upgraded

# Use curl to grab files from MariaDB website
apt-get install -y apt-transport-https curl

# Install MariaDB ${MARIADBVER}
# Configure the official gpg key from Maria DB Foundation
mkdir -p /etc/apt/keyrings
curl -o /etc/apt/keyrings/mariadb-keyring.pgp \
'https://mariadb.org/mariadb_release_signing_key.pgp'
# Add MariaDB Repository and Key Repository
cat > /etc/apt/sources.list.d/mariadb.sources <<SUBEOF
X-Repolib-Name: MariaDB
Types: deb
URIs: https://mirrors.accretive-networks.net/mariadb/repo/${MARIADBVER}/ubuntu
Suites: noble
Components: main main/debug
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
SUBEOF

# update package list from mariadb repo
apt-get update
# install the mariadb-server and galera packages from the newly added repo
apt-get install -y mariadb-server galera-4

# MariaDB automatically enables and starts as a 
# part of the Ubuntu package install process
#systemctl stop mariadb
#systemctl disable mariadb

touch /root/3-mariadb-installed

apt-get install -y gnupg
curl -fsSL https://pgp.mongodb.com/server-8.0.asc | \
   gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

echo "deb [ arch=amd64,arm64 \
            signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] \
    https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
    | tee /etc/apt/sources.list.d/mongodb-org-8.0.list

apt-get update
apt-get install -y mongodb-org

touch /root/4-mongodb-installed

useradd -m -p ${PASSWORD} -s /bin/bash ${UNAME}

touch /root/5-user-setup

apt-get install unzip -y
sudo -u ${UNAME} cat > /home/${UNAME}/etl.sql <<SUBEOF
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
  \\\`state\\\` VARCHAR(4)
) ENGINE=InnoDB;

CREATE TABLE \\\`Order\\\` (
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
  FOREIGN KEY (\\\`zip\\\`)
  REFERENCES \\\`City\\\`(\\\`zip\\\`);
ALTER TABLE \\\`Order\\\` ADD CONSTRAINT FK_Order_Customer_customer_id 
  FOREIGN KEY (\\\`customer_id\\\`)
  REFERENCES \\\`Customer\\\`(\\\`id\\\`);
ALTER TABLE \\\`Orderline\\\` ADD CONSTRAINT FK_Orderline_Order_order_id 
  FOREIGN KEY (\\\`order_id\\\`)
  REFERENCES \\\`Order\\\`(\\\`id\\\`);
ALTER TABLE \\\`Orderline\\\` ADD CONSTRAINT FK_Orderline_Product_product_id 
  FOREIGN KEY (\\\`product_id\\\`)
  REFERENCES \\\`Product\\\`(\\\`id\\\`);
ALTER TABLE \\\`PriceHistory\\\` ADD CONSTRAINT FK_PriceHistory_Product_product_id
  FOREIGN KEY (\\\`product_id\\\`)
  REFERENCES \\\`Product\\\`(\\\`id\\\`);

/* Create a table for the raw data with types suited for them */
CREATE TABLE CustomerStaging (
  id BIGINT UNSIGNED PRIMARY KEY,
  firstName VARCHAR(32),
  lastName VARCHAR(30),
  city VARCHAR(32),
  \\\`state\\\` VARCHAR(4),
  zip VARCHAR(10),
  address1 VARCHAR(100),
  address2 VARCHAR(50),
  email VARCHAR(128),
  birthdate VARCHAR(20)
);

LOAD DATA LOCAL INFILE '/home/${UNAME}/customers.csv'
  INTO TABLE CustomerStaging FIELDS TERMINATED BY ','
    OPTIONALLY ENCLOSED BY '"'
  IGNORE 1 LINES;
/* Use a select to transform the data as it is more readable 
   than load data substitutions */
INSERT INTO City (
  SELECT CAST(zip AS DECIMAL(5)), 
      TRIM('"' FROM city), 
      \\\`state\\\`
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
LOAD DATA LOCAL INFILE '/home/${UNAME}/orders.csv'
  INTO TABLE OrderStaging FIELDS TERMINATED BY ','
    OPTIONALLY ENCLOSED BY '"'
  IGNORE 1 LINES
;
/* Use a select to transform the data as it is more readable than 
   load data substitutions */
INSERT INTO \\\`Order\\\` (
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
LOAD DATA LOCAL INFILE '/home/${UNAME}/products.csv'
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
LOAD DATA LOCAL INFILE '/home/${UNAME}/orderlines.csv'
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
SUBEOF

sudo -u ${UNAME} cat > /home/${UNAME}/views.sql <<SUBEOF
SOURCE /home/${UNAME}/etl.sql

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
    JOIN \\\`Order\\\` O ON O.customer_id = C.id
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

SUBEOF

chown ${UNAME}:${UNAME} /home/${UNAME}/etl.sql
chmod 755 /home/${UNAME}/etl.sql
chown ${UNAME}:${UNAME} /home/${UNAME}/views.sql
chmod 755 /home/${UNAME}/views.sql

cat > /root/run_etl.sh <<SUBEOF
#!/bin/bash
# shebang so the shell knows this is a shell script

if [ ! -e "/home/${UNAME}/${TAMUUID}.zip" ]; then
  sudo -u ${UNAME} wget http://622.gomillion.org/data/${TAMUUID}.zip -O \
    /home/${UNAME}/${TAMUUID}.zip
  sudo -u ${UNAME} unzip /home/${UNAME}/${TAMUUID}.zip -d /home/${UNAME}
fi

mariadb <<SUBSUBEOF
CREATE DATABASE IF NOT EXISTS POS;
CREATE USER IF NOT EXISTS '${UNAME}'@'localhost' IDENTIFIED BY '${PASSWORD}';
GRANT ALL PRIVILEGES ON POS.* TO '${UNAME}'@'localhost';
FLUSH PRIVILEGES;

SUBSUBEOF

# Allows creation of functions and triggers
mariadb -e "SET GLOBAL log_bin_trust_function_creators = 1;"
# Allows local data to be loaded
mariadb -e "SET GLOBAL local_infile = 1;"
sudo -u ${UNAME} cat /home/${UNAME}/views.sql \
  | sudo -u ${UNAME} mariadb -u ${UNAME} --password=${PASSWORD}
# Return to safety
mariadb -e "SET GLOBAL log_bin_trust_function_creators = 0;"
mariadb -e "SET GLOBAL local_infile = 0;"

touch /root/8-etl-done
SUBEOF
chmod 700 /root/run_etl.sh

cat > /root/export_json.sh <<SUBEOF
if [ ! -d ${OUTFILE_DIR} ]; then
  mkdir /var/lib/mysql_files
  chown mysql:mysql /var/lib/mysql_files
fi

if [ ! -e "${PROD_OUT}" ]; then
# 
mariadb <<'SUBSUBEOF'
USE POS;

SELECT JSON_OBJECT("ProductID", P.id, 
    "ProductName", P.name, 
    "ProductBuyers", JSON_ARRAYAGG(DISTINCT 
      JSON_OBJECT("CustomerID", C.id, 
        "CustomerName", CONCAT(C.firstName, " ", C.lastName)
      )
    )
  )
  FROM Product P 
  LEFT JOIN Orderline OL ON OL.product_id = P.id 
  JOIN \\\`Order\\\` O ON O.id = OL.order_id 
  JOIN Customer C ON C.id = O.customer_id 
  GROUP BY P.id, P.name 
  ORDER BY P.id 
  INTO OUTFILE "${PROD_OUT}"
;
SUBSUBEOF
jq . "$PROD_OUT" > "$PROD_OUT.pretty"
fi

if [ ! -e "${CUST_OUT}" ]; then
mariadb <<'SUBSUBEOF'
USE POS;
SELECT JSON_OBJECT(
    "CustomerID", C.id,
    "CustomerName", CONCAT(C.firstName, " ", C.lastName),
    "PrintedAddress1", CONCAT(address1, 
      IF(C.address2 IS NOT NULL, CONCAT(" #", C.address2), "")
    ),
    "PrintedAddress2", CONCAT(Ci.city, ", ", Ci.state, " \ \ ", C.zip),
    "Orders", IFNULL(JSON_ARRAYAGG(OI.result), JSON_ARRAY())
  )
  FROM Customer C
  JOIN City Ci ON Ci.zip = C.zip
  -- Surprisingly a non-correlated subquery appears to be more efficient here
  -- I think the optimization engine is able to cache this query
  -- It saves an additional subquery but uses more memory
  -- If the data set gets larger it can be turned into a WITH/correlated
  LEFT JOIN ( 
    SELECT O.customer_id AS id, 
      JSON_OBJECT(
        "OrderID", O.id,
        "OrderTotal", ROUND(SUM(P.currentPrice * OL.quantity), 2),
        "OrderDate", O.datePlaced,
        "ShippingDate", O.dateShipped,
        "Items", JSON_ARRAYAGG(
          JSON_OBJECT(
            "ProductID", P.id,
            "Quantity", OL.quantity,
            "ProductName", P.name
          )
        )
      ) AS result
    FROM \\\`Order\\\` O
    JOIN Orderline OL ON OL.order_id = O.id
    JOIN Product P ON P.id = OL.product_id
    GROUP BY O.id, O.datePlaced, O.dateShipped
    ORDER BY O.id
  ) OI ON OI.id = C.id
  GROUP BY C.id, C.firstName, C.lastName, C.address1, C.address2, OI.id
  ORDER BY C.id
  INTO OUTFILE "${CUST_OUT}"
;
SUBSUBEOF
jq . "$CUST_OUT" > "$CUST_OUT.pretty"
fi

if [ ! -e "$CUSTOM1_OUT" ]; then
mariadb <<'SUBSUBEOF'
# Business case 1
# There is a need to know which regions prefer which products 
# to determine which stores to sell certain products at
# TODO examine historical price data to retrieve price at time of purchase
USE POS;
SELECT JSON_OBJECT(
    "ZIP", CAST(Ci.zip AS CHAR),
    "State", Ci.state,
    "City", Ci.city,
    "PopularProducts", COALESCE(JSON_ARRAYAGG(PP.result), JSON_ARRAY())
  )
  FROM City Ci
  JOIN (
    SELECT C.zip AS zip, 
      JSON_OBJECT(
        "TotalPurchases", SUM(IFNULL(OL.quantity, 0)),
        "TotalSales", ROUND(
          SUM(IFNULL(OL.quantity, 0) * P.currentPrice), 2
        ),
        "ProductID", P.id,
        "ProductName", P.name
      ) AS result
    FROM Product P
    LEFT JOIN Orderline OL ON OL.product_id = P.id
    JOIN \\\`Order\\\` O ON O.id = OL.order_id
    JOIN Customer C ON C.id = O.customer_id
    GROUP BY C.zip, P.id, P.name
    ORDER BY P.id
  ) PP ON PP.zip = Ci.zip
  GROUP BY Ci.zip, Ci.state, Ci.city
  INTO OUTFILE "$CUSTOM1_OUT"
;
SUBSUBEOF
jq . "$CUSTOM1_OUT" > "$CUSTOM1_OUT.pretty"
fi

if [ ! -e "$CUSTOM2_OUT" ]; then
mariadb <<'SUBSUBEOF'
# Business case 2
# There is a need to know what times of year to keep certain items 
# in higher regional stock so that shipping times are not effected
# TODO examine historical price data to retrieve price at time of purchase
USE POS;
SELECT JSON_OBJECT(
    "OrderMonth", PP.orderMonth,
    "State", Ci.state,
    "PopularProducts", COALESCE(JSON_ARRAYAGG(PP.result), JSON_ARRAY())
  )
  FROM City Ci
  JOIN (
    SELECT C.zip AS zip,
      MONTH(O.datePlaced) AS orderMonth, 
      JSON_OBJECT(
        "TotalPurchases", SUM(OL.quantity),
        "TotalSales", ROUND(
          SUM(OL.quantity * P.currentPrice), 2
        ),
        "ProductID", P.id,
        "ProductName", P.name
      ) AS result
    FROM Product P
    LEFT JOIN Orderline OL ON OL.product_id = P.id
    JOIN \\\`Order\\\` O ON O.id = OL.order_id
    JOIN Customer C ON C.id = O.customer_id
    GROUP BY C.zip, P.id, P.name, MONTH(O.datePlaced)
  ) PP ON PP.zip = Ci.zip
  GROUP BY Ci.state, PP.orderMonth
  INTO OUTFILE "$CUSTOM2_OUT"
;
SUBSUBEOF
jq . "$CUSTOM2_OUT" > "$CUSTOM2_OUT.pretty"
fi

touch /root/9-export_json

SUBEOF
chmod 700 /root/export_json.sh

touch /root/10-startup-done

rm /root/0-script-failed

echo "SUCCESS"
EOF

# BEGIN AWS CLI script

# Check for security group and create if it doesn't exist
SGID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$SGNAME" \
  --query "$SGIDPARSE" \
  --output text)
if [ $? -eq 0 ] && [ ${#SGID} -gt 7 ];
then
  echo "Security Group '$SGNAME' Exists"
elif [ $? -eq 0 ] && [ ${#SGID} -lt 8 ];
then
  echo "Creating Security Group '$SGNAME'"
  # Add security group and retrieve new Group ID
  SGID=$(aws ec2 create-security-group \
    --group-name $SGNAME \
    --description "$SGDESC" \
    --query "GroupId" \
    --output text)
  # Add SSH port rule
  aws ec2 authorize-security-group-ingress \
    --group-id "$SGID" \
    --protocol tcp \
    --port 22 \
    --cidr "$MYIP"
  # Add MariaDB and Galera ports
  for i in "${PORTS[@]}";
  do
    PAIR=( $i )
    aws ec2 authorize-security-group-ingress \
      --group-id "$SGID" \
      --ip-permissions \
        "$(ip_permissions_str $SGID ${PAIR[0]} ${PAIR[1]} $MYACCT)"
  done
fi

if [ $? -ne 0 ]; then
  $("${UNPASTE}")
fi

# Start Instance A and retrieve AWS instance ID
# These need to be in quotes because of the startup script included
INSTANCEA="$( aws ec2 run-instances \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=A}]" \
  --image-id "$IMAGEID" \
  --count 1 \
  --instance-type "$INSTTYPE" \
  --key-name "$KEYNAME" \
  --security-group-ids "$SGID" \
  --query "Instances[0].InstanceId" \
  --iam-instance-profile Name="$IAMPROFILE" \
  --user-data "${STARTUP}" \
  --output text )"

if [ $? -ne 0 ]; then
  $("${UNPASTE}")
fi

# Give a little time for everything to start smoothly
sleep 1

# Wait for instance A to boot
while [ $(aws ec2 describe-instances \
  --filters "Name=instance-id,Values=$INSTANCEA" \
  --query "Reservations[].Instances[].State.Name" \
  --output text ) != "running" ]; 
do
  echo "Wait for instance A to finish boot..."
  sleep 10
done
if [ $? -ne 0 ]; then
  $("${UNPASTE}")
fi

# Instance A should have a private IP now
INSTANCEAIP=$(aws ec2 describe-instances \
  --filters "Name=instance-id,Values=$INSTANCEA" \
  --query "Reservations[].Instances[].PrivateIpAddress" \
  --output text | sed "s/-/\./g" )

if [ $? -ne 0 ]; then
  $("${UNPASTE}")
fi

echo "Instance A has started with local IP $INSTANCEAIP"

# Wait for instance A to be ready for commands
while [ "$(aws ssm get-connection-status \
        --target $INSTANCEA \
        --query 'Status' \
        --output 'text')" != "connected" ];
do
  echo "Wait for instance A to finish initializing..."
  sleep 10
done
echo "Instance A is ready for commands"

if [ $? -ne 0 ]; then
  $("${UNPASTE}")
fi

# It sometimes takes a few seconds to actually be ready after it says it is
sleep 10

comm_send_wait "$INSTANCEA" "cloud-init status --wait" \
  "Wait for instance A to finish setup..." COMMID 

# Retreive final command response code because this tells if it worked
# Clear paste queue if it failed
if [ $? -ne 0 || $(aws ssm get-command-invocation \
  --command-id "$COMMID" \
  --instance-id "$INSTANCEA" \
  --query "ResponseCode" \
  --output text ) -ne 0 ]; then
  $("${UNPASTE}")
fi
echo "A has finished setup"

# Run etl on instance A
comm_send_wait "INSTANCEA" "/root/run_etl.sh" \
  "Wait for instance A to finish etl..." COMMID
  
# Retreive final command response code because this tells if it worked
# Clear paste queue if it failed
if [ $? -ne 0 || $(aws ssm get-command-invocation \
  --command-id "$COMMID" \
  --instance-id "$INSTANCEA" \
  --query "ResponseCode" \
  --output text ) -ne 0 ]; then
  $("${UNPASTE}")
fi
echo "Instance A has finished etl"

# Run json export on instance A

comm_send_wait "INSTANCEA" "/root/json_export.sh" \
  "Wait for instance A to finish json export..." COMMID

# Retreive final command response code because this tells if it worked
# Clear paste queue if it failed
if [ $? -ne 0 || $(aws ssm get-command-invocation \
  --command-id "$COMMID" \
  --instance-id "$INSTANCEA" \
  --query "ResponseCode" \
  --output text ) -ne 0 ]; then
  $("${UNPASTE}")
fi
echo "Instance A has finished json export"

echo "SUCCESS"

# TESTS FOR RUNNING
echo "ls -la ${OUTFILE_DIR}"
echo "sudo head -n 1 ${PROD_OUT}"
echo "sudo head -n 1 ${CUST_OUT}"
echo "sudo head -n 1 ${CUSTOM1_OUT}"
echo "sudo head -n 1 ${CUSTOM2_OUT}"


# WHEN DONE, DELETE INSTANCES WITH
echo "aws ec2 terminate-instances --instance-ids $INSTANCEA"

