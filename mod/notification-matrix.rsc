#!rsc by RouterOS
# RouterOS script: mod/notification-matrix
# Copyright (c) 2013-2024 Michael Gisbers <michael@gisbers.de>
#                         Christian Hesse <mail@eworm.de>
# https://git.eworm.de/cgit/routeros-scripts/about/COPYING.md
#
# requires RouterOS, version=7.13
#
# send notifications via Matrix
# https://git.eworm.de/cgit/routeros-scripts/about/doc/mod/notification-matrix.md

:global FlushMatrixQueue;
:global NotificationFunctions;
:global PurgeMatrixQueue;
:global SendMatrix;
:global SendMatrix2;
:global SetupMatrixAuthenticate;
:global SetupMatrixJoinRoom;

# flush Matrix queue
:set FlushMatrixQueue do={
  :global MatrixQueue;

  :global IsFullyConnected;
  :global LogPrint;

  :if ([ $IsFullyConnected ] = false) do={
    $LogPrint debug $0 ("System is not fully connected, not flushing.");
    :return false;
  }

  :local AllDone true;
  :local QueueLen [ :len $MatrixQueue ];

  :if ([ :len [ /system/scheduler/find where name="_FlushMatrixQueue" ] ] > 0 && $QueueLen = 0) do={
    $LogPrint warning $0 ("Flushing Matrix messages from scheduler, but queue is empty.");
  }

  :foreach Id,Message in=$MatrixQueue do={
    :if ([ :typeof $Message ] = "array" ) do={
      :do {
        /tool/fetch check-certificate=yes-without-crl output=none \
          http-header-field=($Message->"headers") http-method=post \
          ("https://" . $Message->"homeserver" . "/_matrix/client/r0/rooms/" . $Message->"room" . \
           "/send/m.room.message?access_token=" . $Message->"accesstoken") \
          http-data=("{ \"msgtype\": \"m.text\", \"body\": \"" . $Message->"plain" . "\"," . \
           "\"format\": \"org.matrix.custom.html\", \"formatted_body\": \"" . \
           $Message->"formatted" . "\" }") as-value;
        :set ($MatrixQueue->$Id);
      } on-error={
        $LogPrint debug $0 ("Sending queued Matrix message failed.");
        :set AllDone false;
      }
    }
  }

  :if ($AllDone = true && $QueueLen = [ :len $MatrixQueue ]) do={
    /system/scheduler/remove [ find where name="_FlushMatrixQueue" ];
    :set MatrixQueue;
  }
}

# send notification via Matrix - expects one array argument
:set ($NotificationFunctions->"matrix") do={
  :local Notification $1;

  :global Identity;
  :global IdentityExtra;
  :global MatrixAccessToken;
  :global MatrixAccessTokenOverride;
  :global MatrixHomeServer;
  :global MatrixHomeServerOverride;
  :global MatrixQueue;
  :global MatrixRoom;
  :global MatrixRoomOverride;

  :global EitherOr;
  :global FetchUserAgentStr;
  :global LogPrint;
  :global SymbolForNotification;

  :local PrepareText do={
    :local Input [ :tostr $1 ];

    :if ([ :len $Input ] = 0) do={
      :return "";
    }

    :local Return "";
    :local Chars {
      "plain"={ "\\"; "\""; "\n" };
      "format"={ "\\"; "\""; "\n"; "&"; "<"; ">" };
    }
    :local Subs {
      "plain"={ "\\\\"; "\\\""; "\\n" };
      "format"={ "\\\\"; "&quot;"; "<br/>"; "&amp;"; "&lt;"; "&gt;" };
    }

    :for I from=0 to=([ :len $Input ] - 1) do={
      :local Char [ :pick $Input $I ];
      :local Replace [ :find ($Chars->$2) $Char ];

      :if ([ :typeof $Replace ] = "num") do={
        :set Char ($Subs->$2->$Replace);
      }
      :set Return ($Return . $Char);
    }

    :return $Return;
  }

  :local AccessToken [ $EitherOr ($MatrixAccessTokenOverride->($Notification->"origin")) $MatrixAccessToken ];
  :local HomeServer [ $EitherOr ($MatrixHomeServerOverride->($Notification->"origin")) $MatrixHomeServer ];
  :local Room [ $EitherOr ($MatrixRoomOverride->($Notification->"origin")) $MatrixRoom ];

  :if ([ :len $AccessToken ] = 0 || [ :len $HomeServer ] = 0 || [ :len $Room ] = 0) do={
    :return false;
  }

  :local Headers ({ [ $FetchUserAgentStr ($Notification->"origin") ] });
  :local Plain [ $PrepareText ("## [" . $IdentityExtra . $Identity . "] " . \
    ($Notification->"subject") . "\n```\n" . ($Notification->"message") . "\n```") "plain" ];
  :local Formatted ("<h2>" . [ $PrepareText ("[" . $IdentityExtra . $Identity . "] " . \
    ($Notification->"subject")) "format" ] . "</h2>" . "<pre><code>" . \
    [ $PrepareText ($Notification->"message") "format" ] . "</code></pre>");
  :if ([ :len ($Notification->"link") ] > 0) do={
    :set Plain ($Plain . "\\n" . [ $SymbolForNotification "link" ] . \
      [ $PrepareText ("[" . $Notification->"link" . "](" . $Notification->"link" . ")") "plain" ]);
    :set Formatted ($Formatted . "<br/>" . [ $SymbolForNotification "link" ] . \
      "<a href=\\\"" . [ $PrepareText ($Notification->"link") "format" ] . "\\\">" . \
      [ $PrepareText ($Notification->"link") "format" ] . "</a>");
  }

  :do {
    /tool/fetch check-certificate=yes-without-crl output=none \
      http-header-field=$Headers http-method=post \
      ("https://" . $HomeServer . "/_matrix/client/r0/rooms/" . $Room . \
       "/send/m.room.message?access_token=" . $AccessToken) \
      http-data=("{ \"msgtype\": \"m.text\", \"body\": \"" . $Plain . "\"," . \
       "\"format\": \"org.matrix.custom.html\", \"formatted_body\": \"" . \
       $Formatted . "\" }") as-value;
  } on-error={
    $LogPrint info $0 ("Failed sending Matrix notification! Queuing...");

    :if ([ :typeof $MatrixQueue ] = "nothing") do={
      :set MatrixQueue ({});
    }
    :local Text ([ $SymbolForNotification "alarm-clock" ] . \
      "This message was queued since " . [ /system/clock/get date ] . \
      " " . [ /system/clock/get time ] . " and may be obsolete.");
    :set Plain ($Plain . "\\n" . $Text);
    :set Formatted ($Formatted . "<br/>" . $Text);
    :set ($MatrixQueue->[ :len $MatrixQueue ]) { headers=$Headers; \
        accesstoken=$AccessToken; homeserver=$HomeServer; room=$Room; \
        plain=$Plain; formatted=$Formatted };
    :if ([ :len [ /system/scheduler/find where name="_FlushMatrixQueue" ] ] = 0) do={
      /system/scheduler/add name="_FlushMatrixQueue" interval=1m start-time=startup \
        on-event=(":global FlushMatrixQueue; \$FlushMatrixQueue;");
    }
  }
}

# purge the Matrix queue
:set PurgeMatrixQueue do={
  :global MatrixQueue;

  /system/scheduler/remove [ find where name="_FlushMatrixQueue" ];
  :set MatrixQueue;
}

# send notification via Matrix - expects at least two string arguments
:set SendMatrix do={
  :global SendMatrix2;

  $SendMatrix2 ({ origin=$0; subject=$1; message=$2; link=$3 });
}

# send notification via Matrix - expects one array argument
:set SendMatrix2 do={
  :local Notification $1;

  :global NotificationFunctions;

  ($NotificationFunctions->"matrix") ("\$NotificationFunctions->\"matrix\"") $Notification;
}

# setup - get home server and access token
:set SetupMatrixAuthenticate do={
  :local User [ :tostr $1 ];
  :local Pass [ :tostr $2 ];

  :global FetchUserAgentStr;
  :global LogPrint;

  :global MatrixAccessToken;
  :global MatrixHomeServer;

  :local Domain [ :pick $User ([ :find $User ":" ] + 1) [ :len $User] ];
  :do {
    :local Data ([ /tool/fetch check-certificate=yes-without-crl output=user \
        http-header-field=({ [ $FetchUserAgentStr $0 ] }) \
        ("https://" . $Domain . "/.well-known/matrix/client") as-value ]->"data");
    :set MatrixHomeServer ([ :deserialize from=json value=$Data ]->"m.homeserver"->"base_url");
    $LogPrint debug $0 ("Home server is: " . $MatrixHomeServer);
  } on-error={
    $LogPrint error $0 ("Failed getting home server!");
    :return false;
  }

  :if ([ :pick $MatrixHomeServer 0 8 ] = "https://") do={
    :set MatrixHomeServer [ :pick $MatrixHomeServer 8 [ :len $MatrixHomeServer ] ];
  }

  :do {
    :local Data ([ /tool/fetch check-certificate=yes-without-crl output=user \
        http-header-field=({ [ $FetchUserAgentStr $0 ] }) http-method=post \
        http-data=("{\"type\":\"m.login.password\", \"user\":\"" . $User . "\", \"password\":\"" . $Pass . "\"}") \
        ("https://" . $MatrixHomeServer . "/_matrix/client/r0/login") as-value ]->"data");
    :set MatrixAccessToken ([ :deserialize from=json value=$Data ]->"access_token");
    $LogPrint debug $0 ("Access token is: " . $MatrixAccessToken);
  } on-error={
    $LogPrint error $0 ("Failed logging in (and getting access token)!");
    :return false;
  }

  :do {
    /system/script/remove [ find where name="global-config-overlay.d/mod/notification-matrix" ];
    /system/script/add name="global-config-overlay.d/mod/notification-matrix" source=( \
      "# configuration snippet: mod/notification-matrix\n\n" . \
      ":global MatrixHomeServer \"" . $MatrixHomeServer . "\";\n" . \
      ":global MatrixAccessToken \"" . $MatrixAccessToken . "\";\n");
    $LogPrint info $0 ("Added configuration snippet. Now create and join a room, please!");
  } on-error={
    $LogPrint error $0 ("Failed adding configuration snippet!");
    :return false;
  }
}

# setup - join a room
:set SetupMatrixJoinRoom do={
  :global MatrixRoom [ :tostr $1 ];

  :global FetchUserAgentStr;
  :global LogPrint;
  :global UrlEncode;

  :global MatrixAccessToken;
  :global MatrixHomeServer;
  :global MatrixRoom;

  :do {
    /tool/fetch check-certificate=yes-without-crl output=none \
        http-header-field=({ [ $FetchUserAgentStr $0 ] }) http-method=post http-data="" \
        ("https://" . $MatrixHomeServer . "/_matrix/client/r0/rooms/" . [ $UrlEncode $MatrixRoom ] . \
        "/join?access_token=" . [ $UrlEncode $MatrixAccessToken ]) as-value;
    $LogPrint debug $0 ("Joined the room.");
  } on-error={
    $LogPrint error $0 ("Failed joining the room!");
    :return false;
  }

  :do {
    :local Snippet [ /system/script/find where name="global-config-overlay.d/mod/notification-matrix" ];
    /system/script/set $Snippet source=([ get $Snippet source ] . \
      ":global MatrixRoom \"" . $MatrixRoom . "\";\n");
    $LogPrint info $0 ("Appended configuration to configuration snippet. Please review!");
  } on-error={
    $LogPrint error $0 ("Failed appending configuration to snippet!");
    :return false;
  }
}
